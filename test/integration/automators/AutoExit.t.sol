// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../IntegrationTestBase.sol";

import "../../../src/automators/AutoExit.sol";

contract AutoExitTest is IntegrationTestBase {
    
    AutoExit autoExit;

    function setUp() external {
        _setupBase();
        autoExit = new AutoExit(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60, 100, uint64(Q64 / 400), _getSwapRouterOptions());
    }

    function _setConfig(
        uint tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        int24 token0TriggerTick,
        int24 token1TriggerTick
    ) internal {
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig(
                isActive,
                token0Swap,
                token1Swap,
                token0TriggerTick,
                token1TriggerTick,
                token0SlippageX64,
                token1SlippageX64
            );

        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(tokenId, config);
    }

    function testNoLiquidity() external {
        _setConfig(TEST_NFT, true, false, false, 0, 0, type(int24).min, type(int24).max);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);

        assertEq(liquidity, 0);

        vm.expectRevert(AutoExit.NoLiquidity.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", liquidity, 0, 0, block.timestamp));
    }

    function _addLiquidity() internal returns (uint256 amount0, uint256 amount1) {
         // add onesided liquidity
        vm.startPrank(TEST_NFT_ACCOUNT);
        DAI.approve(address(NPM), 1000000000000000000);
        (, amount0, amount1) = NPM.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(TEST_NFT, 1000000000000000000, 0, 0, 0, block.timestamp));

        assertEq(amount0, 999999999999999633);
        assertEq(amount1, 0);

        vm.stopPrank();
    }

    function testRangesAndActions() external {

        (uint amount0, uint amount1) = _addLiquidity();
        
        (, ,address token0, address token1, uint24 fee , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})));

        (, int24 tick, , , , , ) = pool.slot0();

        assertGt(liquidity, 0);
        assertEq(tickLower, -276320);
        assertEq(tickUpper, -276310);
        assertEq(tick, -276325);
    
        // test with single approval
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(autoExit), TEST_NFT);

        _setConfig(TEST_NFT, true, false, false, 0, 0, -276325, type(int24).max);
        vm.expectRevert(Automator.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", liquidity,  0, 0, block.timestamp));

        uint balanceBeforeOwner = DAI.balanceOf(TEST_NFT_ACCOUNT);

        _setConfig(TEST_NFT, true, false, false, 0, 0, -276324, type(int24).max);

        // execute limit order - without swap
        vm.prank(OPERATOR_ACCOUNT); 
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", liquidity,  0, 0, block.timestamp));

        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(TEST_NFT);
        assertEq(liquidity, 0);

        uint balanceAfterOwner = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // check paid fee
        uint balanceBefore = DAI.balanceOf(address(this));
        address[] memory addresses = new address[](2);
        addresses[0] = address(DAI);
        addresses[1] = address(USDC);
        vm.prank(WITHDRAWER_ACCOUNT); 
        autoExit.withdrawBalances(addresses, address(this));
        uint balanceAfter = DAI.balanceOf(address(this));

        assertEq(balanceAfterOwner + balanceAfter - balanceBeforeOwner - balanceBefore + 1, amount0); // +1 because Uniswap imprecision (remove same liquidity returns 1 less)

        // is not runnable anymore because configuration was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Automator.NotConfigured.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", liquidity,  0, 0, block.timestamp));

        // add new liquidity
        (amount0, amount1) = _addLiquidity();
        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(TEST_NFT);

        // change to swap
        _setConfig(TEST_NFT, true, true, true, uint64(Q64 / 100), uint64(Q64 / 100), -276324, type(int24).max);

        // execute without swap data fails because not allowed by config
        vm.expectRevert(AutoExit.MissingSwapData.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", liquidity, 0, 0, block.timestamp));

        // execute stop loss order - with swap
        uint swapBalanceBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);

        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, _getDAIToUSDSwapData(), liquidity, 0, 0, block.timestamp));
        uint swapBalanceAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);
        
        // protocol fee
        balanceBefore = USDC.balanceOf(address(this));

        vm.prank(WITHDRAWER_ACCOUNT); 
        autoExit.withdrawBalances(addresses, address(this));

        balanceAfter = USDC.balanceOf(address(this));

        assertEq(swapBalanceAfter - swapBalanceBefore, 991364);
        assertEq(balanceAfter - balanceBefore, 2484);
    }

     function testDirectSendNFT() external {
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer")); // NFT manager doesnt resend original error for some reason
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(autoExit), TEST_NFT);
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = autoExit.maxTWAPTickDifference();
        autoExit.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoExit.TWAPSeconds(), 120);

        vm.expectRevert(Automator.InvalidConfig.selector);
        autoExit.setTWAPConfig(maxTWAPTickDifference, 30);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 TWAPSeconds = autoExit.TWAPSeconds();
        autoExit.setTWAPConfig(5, TWAPSeconds);
        assertEq(autoExit.maxTWAPTickDifference(), 5);

        vm.expectRevert(Automator.InvalidConfig.selector);
        autoExit.setTWAPConfig(600, TWAPSeconds);
    }

    function testSetOperator() external {
        assertEq(autoExit.operators(TEST_NFT_ACCOUNT), false);
        autoExit.setOperator(TEST_NFT_ACCOUNT, true);
        assertEq(autoExit.operators(TEST_NFT_ACCOUNT), true);
    }


    function testUnauthorizedSetConfig() external {
        vm.expectRevert(Automator.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(TEST_NFT, AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testInvalidConfig() external {
        vm.expectRevert(Automator.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(TEST_NFT, AutoExit.PositionConfig(true, false, false,  800000, -800000, 0, 0));
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        AutoExit.PositionConfig memory configIn = AutoExit.PositionConfig(true, false, false, -800000, 800000, 0, 0);
        autoExit.configToken(TEST_NFT, configIn);
        (bool i1, bool i2, bool i3, int24 i4, int24 i5, uint64 i6, uint64 i7) = autoExit.positionConfigs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(AutoExit.PositionConfig(i1, i2, i3, i4, i5, i6, i7)));
    }

    function testNonOperator() external {
        vm.expectRevert(Automator.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", 0,  0, 0, block.timestamp));
    }

    function testRunWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(true, false, false, -84121, -78240, 0, 0));

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("Not approved"));
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", liquidity,  0, 0, block.timestamp));
    }

    function testLiquidityChanged() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(true, false, false, -84121, -78240, 0, 0));

        // fails when sending NFT
        vm.expectRevert(Automator.LiquidityChanged.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", 0,  0, 0, block.timestamp));
    }

    function testRunWithoutConfig() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.expectRevert(Automator.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT, "", 0,  0, 0, block.timestamp));
    }

    function testRunNotReady() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2_A, AutoExit.PositionConfig(true, false, false, -276331, -276320, 0, 0));

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2_A);

        // in range position cant be run
        vm.expectRevert(Automator.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2_A, "", liquidity,  0, 0, block.timestamp));
    }

    function testOracleCheck() external {

        // create range adjustor with more strict oracle config    
        autoExit = new AutoExit(NPM, OPERATOR_ACCOUNT, WITHDRAWER_ACCOUNT, 60 * 30, 4, uint64(Q64 / 400), _getSwapRouterOptions());

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(true, true, true, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100)));

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // TWAPCheckFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Automator.TWAPCheckFailed.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), liquidity,  0, 0, block.timestamp));
    }

    // tests LimitOrder without adding to module
    function testLimitOrder() external {

        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(true, false, false, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max slippage

        uint contractWETHBalanceBefore = WETH_ERC20.balanceOf(address(autoExit));
        uint contractDAIBalanceBefore = DAI.balanceOf(address(autoExit));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // test max withdraw slippage
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert("Price slippage check");
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", liquidity, type(uint).max, type(uint).max, block.timestamp));

        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", liquidity, 0, 0, block.timestamp)); // max fee with 1% is 7124618988448545

        (, , , , , , , liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // is not runnable anymore because configuration was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Automator.NotConfigured.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", liquidity, 0, 0, block.timestamp));

        // fee stored for owner in contract (only WETH because WETH is target token)
        assertEq(WETH_ERC20.balanceOf(address(autoExit)) - contractWETHBalanceBefore, 1267257651391530);
        assertEq(DAI.balanceOf(address(autoExit)) - contractDAIBalanceBefore, 779194049850154725);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 310898425890211735621); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 505635802905220511); // all available
    }

    // tests StopLoss without adding to module
    function testStopLoss() external {
        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(autoExit), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        autoExit.configToken(TEST_NFT_2, AutoExit.PositionConfig(true, true, true, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max slippage

        uint contractWETHBalanceBefore = WETH_ERC20.balanceOf(address(autoExit));
        uint contractDAIBalanceBefore = DAI.balanceOf(address(autoExit));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // is not runnable without swap
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(AutoExit.MissingSwapData.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, "", liquidity, 0, 0, block.timestamp));

        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), liquidity, 0, 0, block.timestamp));

        (, , , , , , , liquidity, , , , ) = NPM.positions(TEST_NFT_2);

        // is not runnable anymore because configuration was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Automator.NotConfigured.selector);
        autoExit.execute(AutoExit.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), liquidity, 0, 0, block.timestamp));

        // fee stored for owner in contract (because perfect swap all fees are grabbed from target token DAI)
        assertEq(WETH_ERC20.balanceOf(address(autoExit)) - contractWETHBalanceBefore, 0);
        assertEq(DAI.balanceOf(address(autoExit)) - contractDAIBalanceBefore, 2703387416905290365);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 1078651579345210856838); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 0); // all available
    }

    function _getWETHToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=506903060556612041&slippagePercentage=0.25
        return
            abi.encode(
                EX0x,
                hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000708e1a5dc0901c90000000000000000000000000000000000000000000000259f6c7a7e07497b8c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000c4cce18ee664276707"
            );
    }

    function _getDAIToUSDSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=999999999999999632&slippagePercentage=0.05
        return
            abi.encode(
                EX0x,
                hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a763fe9000000000000000000000000000000000000000000000000000000000000e777d000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000045643479ef636e6e94"
            );
    }
}
