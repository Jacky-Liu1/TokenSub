/**
 * @type import('hardhat/config').HardhatUserConfig
 */
require('@nomiclabs/hardhat-waffle')
require('@openzeppelin/hardhat-upgrades');

module.exports = {
  solidity: "0.8.0",
};


/*
COMPILING SMART CONTRACTS
npx hardhat compile


To see hardhat tasks run : npx hardhat
Ex: check, clean, compile, console, flatten, help, node, run, test


DEPLOYMENT:
npx hardhat run scripts/deploy.js 
OR SPECIFY BY NETWORK
npx hardhat run scripts/deploy.js --network rinkeby
npx hardhat run scripts/deploy.js --network localhost


npx hardhat node
*/