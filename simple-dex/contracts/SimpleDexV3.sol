// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";
import "./SimpleDex.sol";

contract SimpleDexV3 is Ownable, SimpleDex {
    /// @dev 유동성 제거 이벤트
    event LiquidityRemoved(
        address indexed provider,
        address tokenA,
        address tokenB,
        uint256 liquidity
    );

    /// @dev 유동성 제거
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity
    ) external {
        require(
            pools[tokenA][tokenB].liquidityOf[msg.sender] >= liquidity,
            "Insufficient liquidity"
        );

        uint256 tokenAReserve = pools[tokenA][tokenB].tokenAReserve;
        uint256 tokenBReserve = pools[tokenA][tokenB].tokenBReserve;
        uint256 totalLiquidity = pools[tokenA][tokenB].totalLiquidity;

        // 먼저 계산 (원래 totalLiquidity 사용)
        uint256 amountA = (liquidity * tokenAReserve) / totalLiquidity;
        uint256 amountB = (liquidity * tokenBReserve) / totalLiquidity;

        // 계산 후 상태 업데이트
        pools[tokenA][tokenB].liquidityOf[msg.sender] -= liquidity;
        pools[tokenA][tokenB].totalLiquidity -= liquidity;
        pools[tokenA][tokenB].tokenAReserve -= amountA;
        pools[tokenA][tokenB].tokenBReserve -= amountB;

        IERC20(tokenA).transfer(msg.sender, amountA);
        IERC20(tokenB).transfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, tokenA, tokenB, liquidity);
    }
}
