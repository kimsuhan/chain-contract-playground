// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/access/Ownable.sol';
import './CToken.sol';

import 'hardhat/console.sol';

interface PriceOracle {
  function getUnderlyingPrice(address cToken) external view returns (uint);
}

interface CTokenInterface {
  function balanceOf(address account) external view returns (uint);

  function borrowBalanceStored(address account) external view returns (uint);

  function totalBorrows() external view returns (uint);

  function totalSupply() external view returns (uint);

  function exchangeRateStored() external view returns (uint);

  function underlying() external view returns (address);
}

contract Comptroller is Ownable {
  constructor() Ownable(msg.sender) {}

  /// @notice 에러 코드 정의
  enum Error {
    NO_ERROR,
    UNAUTHORIZED,
    COMPTROLLER_MISMATCH,
    INSUFFICIENT_SHORTFALL,
    INSUFFICIENT_LIQUIDITY,
    INVALID_CLOSE_AMOUNT_REQUESTED,
    INVALID_COLLATERAL_FACTOR,
    MATH_ERROR,
    MARKET_NOT_ENTERED,
    MARKET_NOT_LISTED,
    MARKET_ALREADY_LISTED,
    TOO_MANY_ASSETS,
    TOO_MUCH_REPAY,
    PRICE_ERROR,
    REJECTION,
    SNAPSHOT_ERROR,
    TOO_MUCH_BORROW
  }

  struct Market {
    bool isListed; // 시장이 등록되어 있는지
    uint collateralFactorMantissa; // 담보 비율 (scaled by 1e18)
    mapping(address => bool) accountMembership; // 계정별 시장 참여 여부
  }

  mapping(address => Market) public markets;
  mapping(address => address[]) public accountAssets; // 계정별 참여 시장 목록
  mapping(address => uint) public borrowCaps; // 시장별 대출 한도

  PriceOracle public oracle; // 가격 오라클
  uint public closeFactorMantissa = 0.5e18; // 청산시 최대 상환 비율 (50%)
  uint public liquidationIncentiveMantissa = 1.08e18; // 청산 인센티브 (8%)
  uint public maxAssets = 10; // 최대 참여 가능 시장 수

  // 일시정지 상태 관리
  mapping(address => bool) public mintGuardianPaused;
  mapping(address => bool) public borrowGuardianPaused;

  /// @notice 이벤트들
  event MarketListed(address cToken);
  event MarketEntered(address cToken, address account);
  event MarketExited(address cToken, address account);
  event NewCollateralFactor(address cToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);
  event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);
  event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

  /**
   * @notice 가격 오라클 설정
   * @dev 가격 오라클이란 토큰의 가격을 조회하는 컨트랙트 (예시: Chainlink)
   * @param newOracle 설정할 가격 오라클 주소
   */
  function _setPriceOracle(PriceOracle newOracle) external onlyOwner returns (uint) {
    console.log('================================= _setPriceOracle ==================================');

    PriceOracle oldOracle = oracle;
    oracle = newOracle;

    emit NewPriceOracle(oldOracle, newOracle);

    return uint(Error.NO_ERROR);
  }

  /**
   * @notice 시장 등록
   * @dev 소유자만 등록이 가능하며 시장에 CToken을 올리는 경우 사용
   * @param cToken 등록할 시장의 주소
   */
  function _supportMarket(address cToken) external onlyOwner returns (uint) {
    console.log('================================= _supportMarket ==================================');

    // 시장에 이미 등록되어 있는 토큰인지 체크
    if (markets[cToken].isListed) {
      // 오류 반환 >> 이렇게 하는 이유는 외부에서 호출할때 유틸리티 함수 사용가능하게 하기 위함
      return uint(Error.MARKET_ALREADY_LISTED);
    }

    // 시장 등록 및 담보 비율 초기화
    markets[cToken].isListed = true;
    markets[cToken].collateralFactorMantissa = 0;

    // 이벤트 발생
    emit MarketListed(cToken);

    // 성공적으로 등록이 완료되었음을 반환
    return uint(Error.NO_ERROR);
  }

  /**
   * @notice 담보 비율 설정
   * @param cToken 담보 비율을 설정할 시장의 주소
   * @param newCollateralFactorMantissa 설정할 담보 비율 (scaled by 1e18)
   */
  function _setCollateralFactor(address cToken, uint newCollateralFactorMantissa) external onlyOwner returns (uint) {
    console.log('================================= _setCollateralFactor ==================================');

    // 시장이 등록되어 있는지 확인
    Market storage market = markets[cToken];
    if (!market.isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    // 담보 비율이 유효한지 확인 (90% 이하)
    if (newCollateralFactorMantissa > 0.9e18) {
      return uint(Error.INVALID_COLLATERAL_FACTOR);
    }

    // 이전 값 저장 및 새 값 설정
    uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
    market.collateralFactorMantissa = newCollateralFactorMantissa;

    emit NewCollateralFactor(cToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

    return uint(Error.NO_ERROR);
  }

  /**
   * @notice 청산 인센티브 설정
   * @param newLiquidationIncentiveMantissa 설정할 청산 인센티브 (scaled by 1e18)
   */
  function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external onlyOwner returns (uint) {
    console.log('================================= _setLiquidationIncentive ==================================');

    uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
    liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

    emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

    return uint(Error.NO_ERROR);
  }

  /**
   * @notice 시장 참여 (담보로 사용하겠다고 선언)
   * @param cTokens 참여할 시장 주소 배열
   * @return results 각 시장에 대한 결과 배열 (0: 성공, 1: 오류)
   */
  function enterMarkets(address[] memory cTokens) public returns (uint[] memory) {
    console.log('================================= enterMarkets ==================================');

    uint[] memory results = new uint[](cTokens.length);

    for (uint i = 0; i < cTokens.length; i++) {
      results[i] = addToMarketInternal(cTokens[i], msg.sender);
    }

    return results;
  }

  /// @notice 시장 나가기
  function exitMarket(address cTokenAddress) external returns (uint) {
    console.log('================================= exitMarket ==================================');

    // 시장에 참여하고 있는지 확인
    Market storage market = markets[cTokenAddress];
    if (!market.accountMembership[msg.sender]) {
      return uint(Error.NO_ERROR); // 이미 참여하지 않음
    }

    // 나가기 전에 대출이 있는지 확인 (간단화된 버전)
    // 실제로는 더 복잡한 유동성 계산이 필요

    // 시장에서 제거
    delete market.accountMembership[msg.sender];

    // accountAssets에서 제거
    address[] storage assets = accountAssets[msg.sender];
    for (uint i = 0; i < assets.length; i++) {
      if (assets[i] == cTokenAddress) {
        assets[i] = assets[assets.length - 1];
        assets.pop();
        break;
      }
    }

    emit MarketExited(cTokenAddress, msg.sender);
    return uint(Error.NO_ERROR);
  }

  /// @notice 예치 허용 여부 체크
  function mintAllowed(address cToken, address minter, uint mintAmount) external returns (uint) {
    console.log('================================= mintAllowed ==================================');

    // 일시정지 상태 체크
    if (mintGuardianPaused[cToken]) {
      return uint(Error.REJECTION);
    }

    // 시장이 등록되어 있는지 확인
    if (!markets[cToken].isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    return uint(Error.NO_ERROR);
  }

  /// @notice 인출 허용 여부 체크
  function redeemAllowed(address cToken, address redeemer, uint redeemTokens) external returns (uint) {
    console.log('================================= redeemAllowed ==================================');

    uint allowed = redeemAllowedInternal(cToken, redeemer, redeemTokens);
    if (allowed != uint(Error.NO_ERROR)) {
      return allowed;
    }

    // 유동성 체크 (간단화된 버전)
    return uint(Error.NO_ERROR);
  }

  /**
   * @notice 대출 허용 여부 체크
   * @param cToken 대출할 시장의 주소
   * @param borrower 대출할 계정의 주소
   * @param borrowAmount 대출할 금액
   * @return 0 on success, otherwise error code
   */
  function borrowAllowed(
    address cToken, // 빌리려는 토큰
    address borrower, // 대출자
    uint borrowAmount // 빌리려는 금액
  ) external returns (uint) {
    console.log('================================= borrowAllowed ==================================');

    // 일시정지 상태 체크
    if (borrowGuardianPaused[cToken]) {
      return uint(Error.REJECTION);
    }

    // 토큰이 마켓에 등록되어 있는지 확인
    if (!markets[cToken].isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    // 차용자가 시장에 참여하지 않았다면 자동으로 참여시킴
    if (!markets[cToken].accountMembership[borrower]) {
      // cToken 컨트랙트에서만 호출 가능
      require(msg.sender == cToken, 'sender must be cToken');

      // 시장에 추가
      uint result = addToMarketInternal(cToken, borrower);
      if (result != uint(Error.NO_ERROR)) {
        return result;
      }
    }

    // 가격 오라클 체크
    if (oracle.getUnderlyingPrice(cToken) == 0) {
      return uint(Error.PRICE_ERROR);
    }

    // 대출 한도 체크
    uint borrowCap = borrowCaps[cToken];
    console.log('borrowCap', borrowCap);
    if (borrowCap != 0) {
      uint totalBorrows = CTokenInterface(cToken).totalBorrows();
      if (totalBorrows + borrowAmount > borrowCap) {
        return uint(Error.TOO_MUCH_BORROW);
      }
    }

    // 계정 유동성 체크
    (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, cToken, borrowAmount);

    if (err != Error.NO_ERROR) {
      return uint(err);
    }

    if (shortfall > 0) {
      return uint(Error.INSUFFICIENT_LIQUIDITY);
    }

    return uint(Error.NO_ERROR);
  }

  /// @notice 상환 허용 여부 체크
  function repayBorrowAllowed(address cToken, address payer, address borrower, uint repayAmount) external returns (uint) {
    console.log('================================= repayBorrowAllowed ==================================');

    // 시장이 등록되어 있는지 확인
    if (!markets[cToken].isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    return uint(Error.NO_ERROR);
  }

  /// @notice 청산 허용 여부 체크
  function liquidateBorrowAllowed(
    address cTokenBorrowed,
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint repayAmount
  ) external returns (uint) {
    console.log('================================= liquidateBorrowAllowed ==================================');

    // 두 시장 모두 등록되어 있는지 확인
    if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    // 차용자가 청산 가능한 상태인지 체크 (shortfall > 0)
    (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
    if (err != Error.NO_ERROR) {
      return uint(err);
    }

    if (shortfall == 0) {
      return uint(Error.INSUFFICIENT_SHORTFALL);
    }

    return uint(Error.NO_ERROR);
  }

  /// @notice 계정 유동성 계산
  function getAccountLiquidity(address account) external view returns (uint, uint, uint) {
    console.log('================================= getAccountLiquidity ==================================');

    (Error err, uint liquidity, uint shortfall) = getAccountLiquidityInternal(account);
    return (uint(err), liquidity, shortfall);
  }

  /// @notice 참여 중인 시장 목록 조회
  function getAssetsIn(address account) external view returns (address[] memory) {
    console.log('================================= getAssetsIn ==================================');

    return accountAssets[account];
  }

  /// @notice 청산시 압류 토큰 수량 계산
  function liquidateCalculateSeizeTokens(
    address cTokenBorrowed,
    address cTokenCollateral,
    uint actualRepayAmount
  ) external view returns (uint, uint) {
    // 가격 정보 가져오기
    uint priceBorrowedMantissa = oracle.getUnderlyingPrice(cTokenBorrowed);
    uint priceCollateralMantissa = oracle.getUnderlyingPrice(cTokenCollateral);

    if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
      return (uint(Error.PRICE_ERROR), 0);
    }

    // 교환 비율 가져오기
    uint exchangeRateMantissa = CTokenInterface(cTokenCollateral).exchangeRateStored();

    // 압류할 토큰 계산
    // seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
    // seizeTokens = seizeAmount / exchangeRate
    uint numerator = actualRepayAmount * liquidationIncentiveMantissa * priceBorrowedMantissa;
    uint denominator = priceCollateralMantissa * exchangeRateMantissa;
    uint seizeTokens = numerator / denominator;

    return (uint(Error.NO_ERROR), seizeTokens);
  }

  /// @notice 대출 한도 설정
  function _setMarketBorrowCaps(address[] calldata cTokens, uint[] calldata newBorrowCaps) external onlyOwner {
    console.log('================================= _setMarketBorrowCaps ==================================');

    uint numMarkets = cTokens.length;
    require(numMarkets == newBorrowCaps.length, 'invalid input');

    for (uint i = 0; i < numMarkets; i++) {
      borrowCaps[cTokens[i]] = newBorrowCaps[i];
    }
  }

  // ========== Internal Functions ==========

  /**
   * @notice 시장에 참여
   * @param cToken 참여할 시장의 주소
   * @param account 참여할 계정의 주소
   * @return 결과 반환 (0: 성공, 1: 오류)
   */
  function addToMarketInternal(address cToken, address account) internal returns (uint) {
    console.log('================================= addToMarketInternal ==================================');

    Market storage market = markets[cToken];

    // 이미 시장에 등록되어 있는지 체크
    if (!market.isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    // 이미 시장에 등록되어 있는지 체크
    if (market.accountMembership[account]) {
      return uint(Error.NO_ERROR); // 이미 참여 중
    }

    // 최대 참여 시장 수 체크 (한계정이 참여할 수 있는 최대 시장 수)
    if (accountAssets[account].length >= maxAssets) {
      return uint(Error.TOO_MANY_ASSETS);
    }

    // 시장에 추가
    market.accountMembership[account] = true;
    accountAssets[account].push(cToken);

    emit MarketEntered(cToken, account);
    return uint(Error.NO_ERROR);
  }

  function redeemAllowedInternal(address cToken, address redeemer, uint redeemTokens) internal view returns (uint) {
    console.log('================================= redeemAllowedInternal ==================================');

    if (!markets[cToken].isListed) {
      return uint(Error.MARKET_NOT_LISTED);
    }

    return uint(Error.NO_ERROR);
  }

  function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
    console.log('================================= getAccountLiquidityInternal ==================================');

    return getHypotheticalAccountLiquidityInternal(account, address(0), 0);
  }

  /**
   * 만약 이 거래가 실행된다면 계정의 유동성이 어떻게 변경되는지 계산하는 함수
   * @param account 계정의 주소
   * @param cTokenModify 변경할 cToken (예: cUSDC)
   * @param borrowAmount 추가 대출 금액
   * @return Error
   * @return 유동성 (변경된 후의 유동성)
   * @return 부족분 (변경된 후의 부족분)
   */
  function getHypotheticalAccountLiquidityInternal(
    address account,
    address cTokenModify,
    uint borrowAmount
  ) internal view returns (Error, uint, uint) {
    console.log('================================= getHypotheticalAccountLiquidityInternal ==================================');

    // 모든 참여 시장에 대해 계산
    address[] memory assets = accountAssets[account];
    uint sumCollateral = 0;
    uint sumBorrowPlusEffects = 0;
    for (uint i = 0; i < assets.length; i++) {
      address asset = assets[i];

      // 가격 정보 가져오기
      uint oraclePrice = oracle.getUnderlyingPrice(asset);
      if (oraclePrice == 0) {
        return (Error.PRICE_ERROR, 0, 0);
      }

      (uint collateralValue, uint borrowValue) = calculateCollateralValue(asset, account, oraclePrice);
      sumCollateral += collateralValue;
      sumBorrowPlusEffects += borrowValue;
    }

    // 가상의 변경사항 적용
    if (cTokenModify != address(0)) {
      uint oraclePrice = oracle.getUnderlyingPrice(cTokenModify);
      if (oraclePrice == 0) {
        return (Error.PRICE_ERROR, 0, 0);
      }

      // 대출 증가
      sumBorrowPlusEffects += (borrowAmount * oraclePrice) / 1e18;
    }

    // 유동성 vs 부족분 계산
    if (sumCollateral > sumBorrowPlusEffects) {
      return (Error.NO_ERROR, sumCollateral - sumBorrowPlusEffects, 0);
    } else {
      return (Error.NO_ERROR, 0, sumBorrowPlusEffects - sumCollateral);
    }
  }

  function calculateCollateralValue(address asset, address account, uint oraclePrice) internal view returns (uint, uint) {
    console.log('================================= calculateCollateralValue ==================================');

    // 잔고 계산
    uint sumCollateral = 0; // 총 담보의 가치
    uint sumBorrowPlusEffects = 0; // 총 대출의 가치

    CToken ctoken = CToken(asset);
    uint cTokenBalance = ctoken.balanceOf(account);
    uint borrowBalance = ctoken.borrowBalanceStored(account);
    uint exchangeRate = ctoken.exchangeRateStored();
    console.log('cTokenBalance', cTokenBalance);
    console.log('borrowBalance', borrowBalance);
    console.log('exchangeRate', exchangeRate);

    // 담보 가치 계산
    uint collateralFactor = markets[asset].collateralFactorMantissa;
    uint underlyingBalance = (cTokenBalance * exchangeRate) / 1e18;
    uint collateralValue = (underlyingBalance * oraclePrice * collateralFactor) / 1e18 / 1e18;
    sumCollateral += collateralValue;

    // 대출 가치 계산
    sumBorrowPlusEffects += (borrowBalance * oraclePrice) / 1e18;

    return (sumCollateral, sumBorrowPlusEffects);
  }
}
