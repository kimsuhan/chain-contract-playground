import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { Signer } from 'ethers';
import { ethers } from 'hardhat';
import { Comptroller, CToken, JumpRateModel, MockDai, MockUsdc, SimplePriceOracle } from '../typechain-types';

describe('SimpleCompounder', () => {
  async function deployMockDai() {
    const MockDai = await ethers.getContractFactory('MockDai');
    const mockDai = await MockDai.deploy();
    return { mockDai };
  }

  async function deployMockUsdc() {
    const MockUsdc = await ethers.getContractFactory('MockUsdc');
    const mockUsdc = await MockUsdc.deploy();
    return { mockUsdc };
  }

  async function deploySimplePriceOracle() {
    const SimplePriceOracle = await ethers.getContractFactory('SimplePriceOracle');
    const simplePriceOracle = await SimplePriceOracle.deploy();
    return { simplePriceOracle };
  }

  async function deployJumpRateModel() {
    const JumpRateModel = await ethers.getContractFactory('JumpRateModel');
    const jumpRateModel = await JumpRateModel.deploy(
      BigInt(0.05 * 1e18), // 5% 기본 이자율
      BigInt(0.12 * 1e18), // 12% 이자율 증가율
      BigInt(4 * 1e18), // 400% 이자율 증가율
      BigInt(0.8 * 1e18), // 0.8% kink
    );

    return { jumpRateModel };
  }

  async function deployComptroller() {
    const Comptroller = await ethers.getContractFactory('Comptroller');
    const comptroller = await Comptroller.deploy();
    return { comptroller };
  }

  async function deployCToken(
    tokenAddress: string,
    comptrollerAddress: string,
    jumpRateModelAddress: string,
    reserveFactorMantissa: bigint,
    name: string,
    symbol: string,
  ) {
    const CToken = await ethers.getContractFactory('CToken');
    const cToken = await CToken.deploy(tokenAddress, comptrollerAddress, jumpRateModelAddress, reserveFactorMantissa, name, symbol);
    return { cToken };
  }

  let mockDai: MockDai;
  let mockUsdc: MockUsdc;
  let simplePriceOracle: SimplePriceOracle;
  let jumpRateModel: JumpRateModel;
  let comptroller: Comptroller;
  const INITIAL_SUPPLY = ethers.parseEther('1000000');
  let owner: Signer;
  let other1: Signer;
  let other2: Signer;
  let other3: Signer;

  // 사전 설정
  before(async () => {
    mockDai = (await loadFixture(deployMockDai)).mockDai;
    mockUsdc = (await loadFixture(deployMockUsdc)).mockUsdc;
    simplePriceOracle = (await loadFixture(deploySimplePriceOracle)).simplePriceOracle;
    jumpRateModel = (await loadFixture(deployJumpRateModel)).jumpRateModel;
    comptroller = (await loadFixture(deployComptroller)).comptroller;
    [owner, other1, other2, other3] = await ethers.getSigners();
  });

  // 1. mockDai의 초기 잔액 체크
  it('mockDai balanceOf', async () => {
    const [owner] = await ethers.getSigners();
    const balance = await mockDai.balanceOf(owner.address);

    expect(balance).to.equal(INITIAL_SUPPLY);
  });

  // 2. mockUsdc의 초기 잔액 체크
  it('mockUsdc balanceOf', async () => {
    const [owner] = await ethers.getSigners();
    const balance = await mockUsdc.balanceOf(owner.address);

    expect(balance).to.equal(INITIAL_SUPPLY);
  });

  // ============================================
  // 3. CToken 배포
  // ============================================
  let cDai: CToken;
  let cUsdc: CToken;
  it('deploy CToken', async () => {
    // 3-1. cDai 배포
    const { cToken: cDais } = await deployCToken(
      await mockDai.getAddress(),
      await comptroller.getAddress(),
      await jumpRateModel.getAddress(),
      BigInt(0.1 * 1e18), // 10%의 예비 자산 비율
      'Compound Dai',
      'cDAI',
    );

    cDai = cDais;
    expect(cDai.target).to.not.equal(0);

    // 3-2. cUsdc 배포
    const { cToken: cUsdcs } = await deployCToken(
      await mockUsdc.getAddress(),
      await comptroller.getAddress(),
      await jumpRateModel.getAddress(),
      BigInt(0.1 * 1e18), // 10%의 예비 자산 비율
      'Compound USDC',
      'cUSDC',
    );

    cUsdc = cUsdcs;
    expect(cUsdc.target).to.not.equal(0);
  });

  // ============================================
  // 4. Comptroller 설정
  // ============================================
  it('set Comptroller', async () => {
    // 4-1. 가격 오라클 설정
    await expect(comptroller._setPriceOracle(simplePriceOracle.target)).to.emit(comptroller, 'NewPriceOracle').withArgs(
      '0x0000000000000000000000000000000000000000', // 기존 오라클 (초기값이기때문에 0x~)
      simplePriceOracle.target, // 새로운 오라클
    );

    // 4-2. 마켓 등록
    await expect(comptroller._supportMarket(cDai.target)).to.emit(comptroller, 'MarketListed').withArgs(cDai.target);

    await expect(comptroller._supportMarket(cUsdc.target)).to.emit(comptroller, 'MarketListed').withArgs(cUsdc.target);

    // 4-3. 마켓 등록을 확인하는데 10n 이면 등록된 것 (오류를 정상적으로 잘 반환하는지 체크)
    const receipt = await comptroller._supportMarket.staticCall(cDai.target);
    expect(receipt).to.equal(10n);

    // 4-4. 담보 비율 설정
    await expect(
      comptroller._setCollateralFactor(cDai.target, BigInt(0.75 * 1e18)), // 75%
    )
      .to.emit(comptroller, 'NewCollateralFactor')
      .withArgs(cDai.target, BigInt(0), BigInt(0.75 * 1e18));

    await expect(
      comptroller._setCollateralFactor(cUsdc.target, BigInt(0.8 * 1e18)), // 80%
    )
      .to.emit(comptroller, 'NewCollateralFactor')
      .withArgs(cUsdc.target, BigInt(0), BigInt(0.8 * 1e18));

    // 4-5. 청산 인센티브 설정 (8%)
    const liquidationIncentive = ethers.parseUnits('1.08', 18);
    await expect(comptroller._setLiquidationIncentive(liquidationIncentive))
      .to.emit(comptroller, 'NewLiquidationIncentive')
      .withArgs(liquidationIncentive, liquidationIncentive);
  });

  // ============================================
  // 5. Oracle 설정
  // ============================================
  it('set Oracle', async () => {
    const cDaiUnderlyingPrice = await simplePriceOracle.setUnderlyingPrice(cDai.target, BigInt(2000 * 1e18)); // DAI = 2000$
    cDaiUnderlyingPrice.wait();

    const cDaiGetUnderlyingPrice = await simplePriceOracle.getUnderlyingPrice(cDai.target);
    expect(cDaiGetUnderlyingPrice).to.equal(BigInt(2000 * 1e18));

    const cUsdcUnderlyingPrice = await simplePriceOracle.setUnderlyingPrice(cUsdc.target, BigInt(1 * 1e18)); // USDC = 1$
    cUsdcUnderlyingPrice.wait();

    const cUsdcGetUnderlyingPrice = await simplePriceOracle.getUnderlyingPrice(cUsdc.target);
    expect(cUsdcGetUnderlyingPrice).to.equal(BigInt(1 * 1e18));
  });

  // ============================================
  // 6. 초기 유동성 제공
  // ============================================
  it('initial liquidity', async () => {
    const initialSupply = BigInt(10000 * 1e18);

    // 최초 잔액이 없는 other1 계정에서 테스트를 진행합니다.
    await mockDai.approve(other1.getAddress(), initialSupply);
    await mockDai.transfer(other1.getAddress(), initialSupply);
    await mockDai.connect(other1).approve(cDai.target, initialSupply);
    await cDai.connect(other1).mint(initialSupply);

    await mockUsdc.approve(other1.getAddress(), initialSupply);
    await mockUsdc.transfer(other1.getAddress(), initialSupply);
    await mockUsdc.connect(other1).approve(cUsdc.target, initialSupply);
    await cUsdc.connect(other1).mint(initialSupply);
  });

  // ============================================
  // 7. 담보로 빌려보기
  // ============================================
  it('borrow', async () => {
    // 7-1. 0원을 갖고있는 other2 에게 일단 1000 USDC 를 주겠습니다.
    await mockUsdc.approve(other2.getAddress(), ethers.parseEther('1000'));
    await mockUsdc.transfer(other2.getAddress(), ethers.parseEther('1000'));

    // 7-2. other2가 일단 담보로 등록하기위해 USDC 를 예치 합니다.
    await mockUsdc.connect(other2).approve(cUsdc.target, ethers.parseEther('1000'));
    await cUsdc.connect(other2).mint(ethers.parseEther('1000'));

    // 7-3. other2가 담보로 등록하기위해 시장에 등록합니다.
    await expect(comptroller.connect(other2).enterMarkets([cUsdc.target]))
      .to.emit(comptroller, 'MarketEntered')
      .withArgs(cUsdc.target, other2.getAddress());

    // 7-4. USDC 를 담보로 DAI를 빌려보겠습니다.
    // 1000 USDC * 80% = 800 USDC 상당까지 빌릴 수 있습니다.
    // 1 DAI 는 2000$ 이고 1USDC 는 1$ 이므로 800$ 를 가지고 있는거고 800$의 가치가 있는 DAI 는 0.4 DAI 입니다.
    // 계산식은 800 / 2000 = 0.4 입니다.
    const borrowAmount = ethers.parseEther('0.4');
    await expect(cDai.connect(other2).borrow(borrowAmount))
      .to.emit(cDai, 'Borrow')
      .withArgs(other2.getAddress(), borrowAmount, borrowAmount, borrowAmount);

    const other2DaiBalance = await mockDai.balanceOf(await other2.getAddress());
    expect(other2DaiBalance).to.equal(borrowAmount);
  });
});

// 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
// 0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc
