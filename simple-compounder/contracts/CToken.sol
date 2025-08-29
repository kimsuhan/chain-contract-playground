// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './InterestRateModel.sol';
import './Comptroller.sol';

contract CToken is ERC20, ReentrancyGuard {
  uint internal constant BASE = 1e18; // 100%
  uint internal constant borrowRateMaxMantissa = 0.0005e16; // 0.0005%
  uint internal constant reserveFactorMaxMantissa = 1e18; // 100%

  address public underlying; // 기초 자산 (ETH의 경우 0x0)
  Comptroller public comptroller;
  InterestRateModel public interestRateModel;

  uint public reserveFactorMantissa;
  uint public accrualBlockNumber;
  uint public borrowIndex;
  uint public totalBorrows;
  uint public totalReserves;

  mapping(address => uint) internal accountTokens;
  mapping(address => uint) internal accountBorrows;

  struct BorrowSnapshot {
    uint principal;
    uint interestIndex;
  }
  mapping(address => BorrowSnapshot) internal accountBorrowSnapshots;

  event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndexNew, uint totalBorrowsNew);
  event Mint(address minter, uint mintAmount, uint mintTokens);
  event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
  event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
  event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);

  constructor(
    address underlying_,
    Comptroller comptroller_,
    InterestRateModel interestRateModel_,
    uint reserveFactorMantissa_,
    string memory name_,
    string memory symbol_
  ) ERC20(name_, symbol_) {
    underlying = underlying_; // 기초 자산 설정
    comptroller = comptroller_; // 컴파운드 컨트랙트 주소 설정
    interestRateModel = interestRateModel_; // 이자율 모델 주소 설정

    /**
     * 예비 자산 비율 설정
     *
     * 대출자들이 내는 이자 중 일부를 "비상금" 으로 따로 모아두는 비율
     */
    reserveFactorMantissa = reserveFactorMantissa_;
    accrualBlockNumber = block.number; // 마지막 이자 누적 블록 번호 설정
    borrowIndex = 1e18;
  }

  /**
   * @notice 이자를 누적 계산하여 업데이트
   * @return 0 on success, otherwise error code
   */
  function accrueInterest() public returns (uint) {
    uint currentBlockNumber = block.number; // 현재 블록 번호 (블록개당 이자가 계속 쌓이기 때문)
    uint accrualBlockNumberPrior = accrualBlockNumber; // 마지막 계산 블록 번호

    // 이미 현재 블록에서 업데이트되었다면 스킵 (중복 계산 방지)
    if (accrualBlockNumberPrior == currentBlockNumber) {
      return 0; // NO_ERROR
    }

    // 현재 상태 저장
    uint cashPrior = getCash();
    uint borrowsPrior = totalBorrows;
    uint reservesPrior = totalReserves;
    uint borrowIndexPrior = borrowIndex;

    // 이자율 가져오기
    uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);

    require(borrowRateMantissa <= borrowRateMaxMantissa, 'Borrow rate is absurdly high');

    // 경과된 블록 수
    uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;

    // 단순 이자 팩터 계산
    // 예를들어 이자율이 0.0001 (블록당 0.01%)
    // 경과한 블록이 100블록이면 0.0001 * 100 = 0.01 (1%) 이자가 생긴다.
    uint simpleInterestFactor = borrowRateMantissa * blockDelta;

    // 누적 이자 게산
    // 이자율 * 대출 잔액 / BASE
    // 예를들어 총 대출 잔액이 10,000 이면 0.01 * 10,000 = 100 (총 이자 100)
    uint interestAccumulated = (simpleInterestFactor * borrowsPrior) / BASE;

    // 새로운 총 대출 금액
    // 예를들어 총 대출 잔액이 10,000 이면 누적이자 100 + 10,000 = 10,100
    uint totalBorrowsNew = interestAccumulated + borrowsPrior;

    /**
     * 예비 자금 업데이트
     *
     * 이번 블록에서 누적된 이자가 100 USDC
     * Reserve Factor가 20% (0.2e18)라면
     * 예비자금으로 적립: 0.2 * 100 = 20 USDC (예비 자금 20)
     * 예금자들이 실제 받는 이자: 100 - 20 = 80 USDC (예금자 이자 80)
     */
    uint totalReservesNew = (reserveFactorMantissa * interestAccumulated) / BASE + reservesPrior;

    // ✅ 핵심 수정: borrowIndex는 borrowsPrior가 0이어도 안전하게 계산
    uint borrowIndexNew = (simpleInterestFactor * borrowIndexPrior) / BASE + borrowIndexPrior;

    // 상태 업데이트
    accrualBlockNumber = currentBlockNumber;
    borrowIndex = borrowIndexNew;
    totalBorrows = totalBorrowsNew;
    totalReserves = totalReservesNew;

    // 이벤트 발생
    emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

    return 0; // NO_ERROR
  }

  // 예치 (Mint)
  function mint(uint mintAmount) external nonReentrant returns (uint) {
    accrueInterest(); // 1단계 이자 계산

    return mintInternal(mintAmount);
  }

  // 실제 예치 함수
  function mintInternal(uint mintAmount) internal returns (uint) {
    // 1. 현재 교환 비율 계산
    uint exchangeRateMantissa = exchangeRateStoredInternal();

    // 2. 발행할 cToken 수량 계산
    uint mintTokens = (mintAmount * 1e18) / exchangeRateMantissa;

    // 3. 원본 토큰을 컨트랙으로 전송
    require(IERC20(underlying).transferFrom(msg.sender, address(this), mintAmount), 'Transfer failed');

    // 4.cToken 발행
    accountTokens[msg.sender] += mintTokens;
    _mint(msg.sender, mintTokens);

    emit Mint(msg.sender, mintAmount, mintTokens);
    return 0;
  }

  /**
   * @notice 대출
   * @param borrowAmount 대출 금액
   * @return 0 on success, otherwise error code
   */
  function borrow(uint borrowAmount) external nonReentrant returns (uint) {
    console.log('================================= borrow =================================');

    accrueInterest();
    return borrowInternal(borrowAmount);
  }

  function borrowInternal(uint borrowAmount) internal returns (uint) {
    console.log('================================= borrowInternal =================================');
    // 유동성 체크 (Comptroller에서)
    uint allowed = comptroller.borrowAllowed(address(this), msg.sender, borrowAmount);
    console.log('allowed', allowed);
    require(allowed == 0, 'Borrow not allowed');

    console.log('getCash', getCash());
    console.log('borrowAmount', borrowAmount);
    require(getCash() >= borrowAmount, 'Insufficient cash');

    // 대출 잔고 업데이트
    BorrowSnapshot storage borrowSnapshot = accountBorrowSnapshots[msg.sender];
    borrowSnapshot.principal = borrowBalanceStoredInternal(msg.sender);
    borrowSnapshot.interestIndex = borrowIndex;

    uint accountBorrowsNew = borrowSnapshot.principal + borrowAmount;
    uint totalBorrowsNew = totalBorrows + borrowAmount;

    accountBorrowSnapshots[msg.sender].principal = accountBorrowsNew;
    totalBorrows = totalBorrowsNew;

    // 토큰 전송
    ERC20 underlyingToken = ERC20(underlying);
    require(underlyingToken.transfer(msg.sender, borrowAmount), 'Transfer failed');

    console.log('symbol', underlyingToken.symbol(), 'name', underlyingToken.name());
    console.log('sender', msg.sender);
    console.log('accountBorrowsNew', accountBorrowsNew);
    console.log('totalBorrowsNew', totalBorrowsNew);

    emit Borrow(msg.sender, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    return 0;
  }

  // 상환 (Repay)
  function repayBorrow(uint repayAmount) external nonReentrant returns (uint) {
    accrueInterest();
    return repayBorrowInternal(repayAmount);
  }

  function repayBorrowInternal(uint repayAmount) internal returns (uint) {
    uint accountBorrowsPrev = borrowBalanceStoredInternal(msg.sender);
    uint repayAmountFinal = repayAmount > accountBorrowsPrev ? accountBorrowsPrev : repayAmount;

    // 토큰 전송
    require(IERC20(underlying).transferFrom(msg.sender, address(this), repayAmountFinal), 'Transfer failed');

    // 대출 잔고 업데이트
    uint accountBorrowsNew = accountBorrowsPrev - repayAmountFinal;
    uint totalBorrowsNew = totalBorrows - repayAmountFinal;

    accountBorrowSnapshots[msg.sender].principal = accountBorrowsNew;
    accountBorrowSnapshots[msg.sender].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;

    emit RepayBorrow(msg.sender, msg.sender, repayAmountFinal, accountBorrowsNew, totalBorrowsNew);
    return 0;
  }

  // 인출 (Redeem)
  function redeem(uint redeemTokens) external nonReentrant returns (uint) {
    accrueInterest();
    return redeemInternal(redeemTokens);
  }

  function redeemInternal(uint redeemTokens) internal returns (uint) {
    uint exchangeRateMantissa = exchangeRateStoredInternal();
    uint redeemAmount = (redeemTokens * exchangeRateMantissa) / 1e18;

    require(getCash() >= redeemAmount, 'Insufficient cash');

    // 유동성 체크
    uint allowed = comptroller.redeemAllowed(address(this), msg.sender, redeemTokens);
    require(allowed == 0, 'Redeem not allowed');

    // cToken 소각
    accountTokens[msg.sender] -= redeemTokens;
    _burn(msg.sender, redeemTokens);

    // 토큰 전송
    require(IERC20(underlying).transfer(msg.sender, redeemAmount), 'Transfer failed');

    emit Redeem(msg.sender, redeemAmount, redeemTokens);
    return 0;
  }

  // Helper functions
  function getCash() public view returns (uint) {
    return IERC20(underlying).balanceOf(address(this));
  }

  function exchangeRateStoredInternal() internal view returns (uint) {
    uint _totalSupply = totalSupply();
    if (_totalSupply == 0) {
      return 1e18; // Initial exchange rate
    } else {
      uint totalCash = getCash();
      uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
      return (cashPlusBorrowsMinusReserves * 1e18) / _totalSupply;
    }
  }

  function borrowBalanceStored(address account) external view returns (uint) {
    return borrowBalanceStoredInternal(account);
  }

  function borrowBalanceStoredInternal(address account) internal view returns (uint) {
    BorrowSnapshot storage borrowSnapshot = accountBorrowSnapshots[account];
    if (borrowSnapshot.principal == 0) {
      return 0;
    }

    return (borrowSnapshot.principal * borrowIndex) / borrowSnapshot.interestIndex;
  }

  function exchangeRateStored() public view returns (uint) {
    return exchangeRateStoredInternal();
  }
}
