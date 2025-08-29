// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";
import "./SimpleDex.sol";

contract SimpleDexV2 is Ownable, SimpleDex {
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

        pools[tokenA][tokenB].liquidityOf[msg.sender] -= liquidity;
        pools[tokenA][tokenB].totalLiquidity -= liquidity;

        uint256 tokenAReserve = pools[tokenA][tokenB].tokenAReserve;
        uint256 tokenBReserve = pools[tokenA][tokenB].tokenBReserve;

        // 토큰 A의 양 계산 (공식 = 유동성 * 토큰 A 총 공급량 / 풀의 총 유동성)
        uint256 amountA = (liquidity * tokenAReserve) /
            pools[tokenA][tokenB].totalLiquidity;

        // 토큰 B의 양 계산 (공식 = 유동성 * 토큰 B 총 공급량 / 풀의 총 유동성)
        uint256 amountB = (liquidity * tokenBReserve) /
            pools[tokenA][tokenB].totalLiquidity;

        IERC20(tokenA).transfer(msg.sender, amountA);
        IERC20(tokenB).transfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, tokenA, tokenB, liquidity);
    }
}
