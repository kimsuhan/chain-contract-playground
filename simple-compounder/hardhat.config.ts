import "@nomicfoundation/hardhat-toolbox";
import dotenv from "dotenv";
import "hardhat-gas-reporter";
import type { HardhatUserConfig } from "hardhat/config";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: "0.8.28",
  networks: {
    ility: {
      url: "https://ily.blockgateway.net",
      chainId: 69923,
      accounts: [process.env.PRIVATE_KEY!],
    },
  },

  gasReporter: {
    enabled: true,
    currency: "KRW",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
    etherscan: process.env.ETHERSCAN_API_KEY,
    showMethodSig: true, // 메서드 시그니처 표시
    showUncalledMethods: false, // 호출 안된 메서드도 표시
    // outputFile: "gas-report.txt", // 결과 파일 저장
  },
};

export default config;
