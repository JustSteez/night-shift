// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {NightShiftVault} from "../src/NightShiftVault.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockToken, MockFeed} from "../test/mocks/Mocks.sol";

/// @notice Robinhood Chain TESTNET demo deploy: mock USDG, mock stock tokens and mock Chainlink feeds
///         (open faucets, testnet only), plus the Night Shift vault with the deployer as owner and agent.
///         forge script script/DeployTestnet.s.sol --rpc-url $RH_TESTNET_RPC --private-key $PRIVATE_KEY --broadcast
contract DeployTestnet is Script {
    uint256 constant USDG = 1e6;
    uint256 constant SPREAD_BPS = 50;
    uint256 constant MAX_TRADE = 10_000 * USDG;
    uint256 constant MAX_EXPOSURE_BPS = 3_000;

    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        MockToken usdg = new MockToken("Mock USDG", "USDG", 6);
        NightShiftVault vault = new NightShiftVault(usdg, deployer, deployer, SPREAD_BPS, MAX_TRADE);

        _list(vault, "Mock Tesla", "TSLA", 250e8, deployer);
        _list(vault, "Mock NVIDIA", "NVDA", 180e8, deployer);
        _list(vault, "Mock Apple", "AAPL", 230e8, deployer);

        usdg.mint(deployer, 100_000 * USDG);
        vm.stopBroadcast();

        console.log("USDG", address(usdg));
        console.log("NightShiftVault", address(vault));
    }

    function _list(NightShiftVault vault, string memory name, string memory symbol, int256 price, address to)
        private
    {
        MockToken stock = new MockToken(name, symbol, 18);
        MockFeed feed = new MockFeed(price);
        vault.listStock(address(stock), AggregatorV3Interface(address(feed)), MAX_EXPOSURE_BPS);
        stock.mint(to, 1_000 ether);
        console.log(symbol, address(stock), address(feed));
    }
}
