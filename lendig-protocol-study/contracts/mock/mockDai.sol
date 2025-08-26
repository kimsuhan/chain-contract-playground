// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDai is ERC20 {
    constructor() ERC20("Mock DAI", "DAI") {
        _mint(msg.sender, 1000000000000000000000000);
    }
}
