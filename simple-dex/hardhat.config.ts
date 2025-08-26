import "@nomicfoundation/hardhat-toolbox";
import dotenv from "dotenv";
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
};

export default config;
