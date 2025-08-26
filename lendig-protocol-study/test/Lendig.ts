import {
  ContractReturnType,
  WalletClient,
} from "@nomicfoundation/hardhat-viem/types";
import { network } from "hardhat";
import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

describe("Lendig", async () => {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();

  let mockDai: ContractReturnType<"MockDai">;
  let mockUsdc: ContractReturnType<"MockUsdc">;
  let simplePriceOracle: ContractReturnType<"SimplePriceOracle">;
  let jumpRateModel: ContractReturnType<"JumpRateModel">;
  let owner: WalletClient;
  let other: WalletClient;

  beforeEach(async () => {
    [owner, other] = await viem.getWalletClients();

    mockDai = await viem.deployContract("MockDai", [], {
      client: { wallet: owner },
    });

    mockUsdc = await viem.deployContract("MockUsdc", [], {
      client: { wallet: owner },
    });

    simplePriceOracle = await viem.deployContract("SimplePriceOracle", [], {
      client: { wallet: owner },
    });

    jumpRateModel = await viem.deployContract("JumpRateModel", [
      BigInt(0.05 * 1e18), // 5% 기본 이자율
      BigInt(0.12 * 1e18), // 12% 이자율 증가율
      BigInt(4 * 1e18), // 400% 이자율 증가율
      BigInt(0.8 * 1e18), // 0.8% kink
    ]);

    assert.ok(mockDai.address);
    assert.ok(mockUsdc.address);
    assert.ok(simplePriceOracle.address);
    assert.ok(jumpRateModel.address);
  });

  it("Comptroller Deploy", async () => {
    const comptroller = await viem.deployContract("Comptroller");
    assert.ok(comptroller.address);

    // CToken > CDAI Deploy
    const cDai = await viem.deployContract(
      "CToken",
      [
        mockDai.address, // 기초 자산 > DAI Token Address
        comptroller.address, // 컨트롤러 컨트랙트 주소
        jumpRateModel.address, // 이자율 모델 주소
        BigInt(0.1 * 1e18), // 10% 예비 자산 비율 설정
        "Compound Dai",
        "cDAI",
      ],
      {
        client: { wallet: owner },
      }
    );

    assert.ok(cDai.address);

    // CToken > CUSDC Deploy
    const cUsdc = await viem.deployContract(
      "CToken",
      [
        mockUsdc.address, // 기초 자산 > USDC Token Address
        comptroller.address, // 컨트롤러 컨트랙트 주소
        jumpRateModel.address, // 이자율 모델 주소
        BigInt(0.1 * 1e18), // 10% 예비 자산 비율 설정
        "Compound USDC",
        "cUSDC",
      ],
      {
        client: { wallet: owner },
      }
    );

    assert.ok(cUsdc.address);

    // CToken > cETH Deploy
    const cEth = await viem.deployContract(
      "CToken",
      [
        "0x0000000000000000000000000000000000000000" as `0x${string}`,
        comptroller.address,
        jumpRateModel.address,
        BigInt(0.1 * 1e18),
        "Compound ETH",
        "cETH",
      ],
      {
        client: { wallet: owner },
      }
    );

    assert.ok(cEth.address);

    // 이게 주소 비교가 안됨..
    // await viem.assertions.emitWithArgs(
    //   comptroller.write._supportMarket([cDai.address]),
    //   comptroller,
    //   "MarketListed",
    //   [cDai.address]
    // );

    // ============================================
    // Comptroller 설정
    // ============================================

    // 1. 가격 오라클 설정
    await comptroller.write._setPriceOracle([simplePriceOracle.address]);

    // 2. CToken 을 시장에 등록
    await comptroller.write._supportMarket([cDai.address]);
    await comptroller.write._supportMarket([cUsdc.address]);
    await comptroller.write._supportMarket([cEth.address]);

    // 3. 담보 비율 설정
    await viem.assertions.emit(
      comptroller.write._setCollateralFactor([
        cDai.address,
        BigInt(0.75 * 1e18),
      ]),
      comptroller,
      "NewCollateralFactor"
    ); // 75%

    await viem.assertions.emit(
      comptroller.write._setCollateralFactor([
        cUsdc.address,
        BigInt(0.8 * 1e18),
      ]),
      comptroller,
      "NewCollateralFactor"
    ); // 80%

    await viem.assertions.emit(
      comptroller.write._setCollateralFactor([
        cEth.address,
        BigInt(0.82 * 1e18),
      ]),
      comptroller,
      "NewCollateralFactor"
    ); // 82%

    // ============================================
    // Oracle 설정
    // ============================================
    await simplePriceOracle.write.setUnderlyingPrice([
      cDai.address,
      BigInt(1 * 1e18), // DAI = 1$
    ]);

    await simplePriceOracle.write.setUnderlyingPrice([
      cUsdc.address,
      BigInt(2000 * 1e18), // USDC = 2000$
    ]);

    await simplePriceOracle.write.setUnderlyingPrice([
      cEth.address,
      BigInt(2000 * 1e18), // ETH = 2000$ (10^18)
    ]);

    // ============================================
    // 추가 설정
    // ============================================

    // 1. 청산 인센티브 설정 (8%)
    await comptroller.write._setLiquidationIncentive([BigInt(1.08 * 1e18)]); // 8%

    // ============================================
    // 초기 유동성 제공
    // ============================================
    const initialSupply = BigInt(10000 * 1e18);

    await mockDai.write.approve([cDai.address, initialSupply]);
    await cDai.write.mint([initialSupply]);

    await mockUsdc.write.approve([cUsdc.address, initialSupply]);
    await cUsdc.write.mint([initialSupply]);

    // ============================================
    // Other 의 프로토콜 테스트
    // ============================================

    // 1. 사용자에게 DAI 발행
    const test = BigInt(1000 * 1e18);
    await mockDai.write.approve([owner.account.address, test]);
    await mockDai.write.transferFrom([
      owner.account.address,
      other.account.address,
      test,
    ]);

    console.log("✅ User received 1000 DAI");

    // 2. DAI 예치하기
    await mockDai.write.approve([cDai.address, test], {
      account: other.account,
    });

    await cDai.write.mint([test], {
      account: other.account,
    });
    console.log("✅ User supplied 1000 DAI");

    // 3. 담보로 사용하기 위해 시장 진입
    await comptroller.write.enterMarkets([[cDai.address]], {
      account: other.account,
    });

    console.log("✅ User entered DAI market");

    // 4. ETH 빌리기 (DAI 담보로)
    // 1000 DAI * 75% = 750 DAI 상당까지 빌릴 수 있음
    // ETH $2000이므로 0.375 ETH까지 가능 -> 0.3 ETH 빌려보자
    await cUsdc.write.borrow([BigInt(0.3 * 1e18)], {
      account: other.account,
    });

    console.log("✅ User borrowed 0.3 ETH");

    // 5. 계정 유동성 확인
    const [err, liquidity, shortfall] =
      await comptroller.read.getAccountLiquidity([other.account.address]);
    console.log("User account liquidity:", liquidity);
    console.log("User account shortfall:", shortfall);

    const usdcBalance = await mockUsdc.read.balanceOf([other.account.address]);
    console.log("User USDC balance:", usdcBalance);

    const daiBalance = await mockDai.read.balanceOf([other.account.address]);
    console.log("User DAI balance:", daiBalance);

    const cUsdcBalance = await cUsdc.read.balanceOf([other.account.address]);
    console.log("User cUSDC balance:", cUsdcBalance);
  });

  // it("should be able to deposit and withdraw", () => {
  //     const lendig = await viem.deployContract("Lendig");
  // });
});
