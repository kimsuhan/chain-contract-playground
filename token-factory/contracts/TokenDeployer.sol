// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Token.sol";

import "hardhat/console.sol";

contract TokenDeployer {
    string[] public tokenSymbols;
    mapping(string => address) public tokenAddresses;

    event TokenDeployed(
        string name,
        string symbol,
        uint256 initialSupply,
        address owner
    );

    modifier alreadyDeployed(string memory symbol) {
        require(tokenAddresses[symbol] == address(0), "Token already deployed");
        _;
    }

    modifier authorized(string memory symbol) {
        require(msg.sender == tokenAddresses[symbol], "Not authorized");
        _;
    }

    function deployToken(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner
    ) public alreadyDeployed(symbol) returns (address token) {
        bytes memory bytecode = abi.encodePacked(
            type(Token).creationCode,
            abi.encode(name, symbol, initialSupply, owner)
        );

        bytes32 salt = keccak256(abi.encodePacked(name, symbol));

        assembly {
            token := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        require(token != address(0), "Token deployment failed");

        tokenAddresses[symbol] = token;
        tokenSymbols.push(symbol);

        emit TokenDeployed(name, symbol, initialSupply, owner);
    }
}
