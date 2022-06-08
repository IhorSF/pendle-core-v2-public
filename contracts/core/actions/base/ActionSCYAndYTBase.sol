// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "../../../interfaces/IPMarketFactory.sol";
import "../../../interfaces/IPMarket.sol";
import "../../../libraries/SCY/SCYUtils.sol";
import "../../../libraries/math/MarketApproxLib.sol";
import "./ActionSCYAndPYBase.sol";
import "./CallbackHelper.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract ActionSCYAndYTBase is ActionSCYAndPYBase, CallbackHelper {
    using Math for uint256;
    using Math for int256;
    using MarketMathCore for MarketState;
    using MarketApproxLib for MarketState;
    using SafeERC20 for ISuperComposableYield;
    using SafeERC20 for IPYieldToken;
    using SCYIndexLib for ISuperComposableYield;

    event SwapYTAndSCY(address indexed user, int256 ytToAccount, int256 scyToAccount);

    /**
    * @notice swap exact SCY to YT with the help of flashswaps & YT tokenization / redemption
    * @dev inner working of this function:
     - `exactScyIn` SCY is transferred to YT contract
     - `market.swapExactPtForScy` is called, which will transfer SCY directly to YT contract & callback is invoked.
        Note that now we owe PT
     - in callback, all SCY in YT contract is used to mint PT + YT, with PT used to pay back the loan, and YT
        transferred to the receiver
    * @dev this function works in conjunction with ActionCallback
     */
    function _swapExactScyForYt(
        address receiver,
        address market,
        uint256 exactScyIn,
        uint256 minYtOut,
        ApproxParams memory guessYtOut,
        bool doPull
    ) internal returns (uint256 netYtOut) {
        (ISuperComposableYield SCY, , IPYieldToken YT) = IPMarket(market).readTokens();
        MarketState memory state = IPMarket(market).readState(false);

        (netYtOut, ) = state.approxSwapExactScyForYt(
            SCY.newIndex(),
            exactScyIn,
            block.timestamp,
            guessYtOut
        );

        // early-check
        require(netYtOut >= minYtOut, "insufficient YT out");

        if (doPull) {
            SCY.safeTransferFrom(msg.sender, address(YT), exactScyIn);
        }

        IPMarket(market).swapExactPtForScy(
            address(YT),
            netYtOut, // exactPtIn = netYtOut
            _encodeSwapExactScyForYt(receiver, minYtOut)
        );

        emit SwapYTAndSCY(receiver, netYtOut.Int(), exactScyIn.neg());
    }

    /**
    * @notice swap exact YT to SCY with the help of flashswaps & YT tokenization / redemption
    * @dev inner working of this function:
     - `exactYtIn` YT is transferred to YT contract
     - `market.swapScyForExactPt` is called, which will transfer PT directly to YT contract & callback is invoked.
        Note that now we owe SCY
     - in callback, all PT + YT in YT contract is used to redeem SCY. A portion of SCY is used to payback the loan,
        the rest is transferred to the `receiver`
    * @dev this function works in conjunction with ActionCallback
     */
    function _swapExactYtForScy(
        address receiver,
        address market,
        uint256 exactYtIn,
        uint256 minScyOut,
        bool doPull
    ) internal returns (uint256 netScyOut) {
        (ISuperComposableYield SCY, , IPYieldToken YT) = IPMarket(market).readTokens();

        if (doPull) {
            YT.safeTransferFrom(msg.sender, address(YT), exactYtIn);
        }

        uint256 preScyBalance = SCY.balanceOf(receiver);

        IPMarket(market).swapScyForExactPt(
            address(YT),
            exactYtIn, // exactPtOut = exactYtIn
            _encodeSwapYtForScy(receiver, minScyOut)
        ); // ignore return

        netScyOut = SCY.balanceOf(receiver) - preScyBalance;

        emit SwapYTAndSCY(receiver, exactYtIn.neg(), netScyOut.Int());
    }

    /**
    * @notice swap SCY to exact YT with the help of flashswaps & YT tokenization / redemption
    * @dev inner working of this function:
     - `market.swapExactPtForScy` is called, which will transfer SCY directly to YT contract & callback is invoked.
        Note that now we owe PT
     - in callback, we will pull in more SCY as needed & mint all SCY to PT + YT. PT is then used to payback the loan
        while YT is transferred to the user
    * @dev this function works in conjunction with ActionCallback
     */
    function _swapScyForExactYt(
        address receiver,
        address market,
        uint256 exactYtOut,
        uint256 maxScyIn
    ) internal returns (uint256 netScyIn) {
        (, , IPYieldToken YT) = IPMarket(market).readTokens();

        IPMarket(market).swapExactPtForScy(
            address(YT),
            exactYtOut, // exactPtIn = exactYtOut
            _encodeSwapScyForExactYt(msg.sender, receiver, maxScyIn)
        );

        emit SwapYTAndSCY(receiver, exactYtOut.Int(), netScyIn.neg());
    }

    /**
    * @notice swap YT to exact SCY with the help of flashswaps & YT tokenization / redemption
    * @dev inner working of this function:
     - transfer netYtIn (received from approx function) to YT contract
     - `market.swapScyForExactPt` is called, which will transfer PT directly to YT contract & callback is invoked.
        Note that now we owe SCY
     - in callback, we will redeem all PT + YT to get SCY. A portion of it is used to payback the loan. The rest is
        transferred to `receiver`
    * @dev this function works in conjunction with ActionCallback
     */
    function _swapYtForExactScy(
        address receiver,
        address market,
        uint256 exactScyOut,
        uint256 maxYtIn,
        ApproxParams memory guessYtIn,
        bool doPull
    ) internal returns (uint256 netYtIn) {
        MarketState memory state = IPMarket(market).readState(false);
        (ISuperComposableYield SCY, , IPYieldToken YT) = IPMarket(market).readTokens();

        (netYtIn, ) = state.approxSwapYtForExactScy(
            SCY.newIndex(),
            exactScyOut,
            block.timestamp,
            guessYtIn
        );

        require(netYtIn <= maxYtIn, "exceed YT in limit");

        if (doPull) {
            YT.safeTransferFrom(msg.sender, address(YT), netYtIn);
        }

        IPMarket(market).swapScyForExactPt(
            address(YT),
            netYtIn, // exactPtOut = netYtIn
            _encodeSwapYtForScy(receiver, exactScyOut)
        ); // ignore return

        emit SwapYTAndSCY(receiver, netYtIn.neg(), exactScyOut.Int());
    }

    /**
     * @notice swap any ERC20 tokens, through Uniswap's forks, to baseToken of the corresponding SCY of YT. These SCY is then
        used to swap to YT. Please refer to swapExactScyForYt for more details.
     */
    function _swapExactRawTokenForYt(
        address receiver,
        address market,
        uint256 exactRawTokenIn,
        uint256 minYtOut,
        address[] calldata path,
        ApproxParams memory guessYtOut,
        bool doPull
    ) internal returns (uint256 netYtOut) {
        (ISuperComposableYield SCY, , IPYieldToken YT) = IPMarket(market).readTokens();

        uint256 netScyUsedToBuyYT = _mintScyFromRawToken(
            address(YT),
            address(SCY),
            exactRawTokenIn,
            1,
            path,
            doPull
        );

        netYtOut = _swapExactScyForYt(
            receiver,
            market,
            netScyUsedToBuyYT,
            minYtOut,
            guessYtOut,
            false
        );
    }

    /**
     * @notice swap YT to SCY (using `swapExactYtForScy` logic), then redeem SCY to baseToken & swap baseToken to rawToken
        through Uniswap's forks
     */
    function _swapExactYtForRawToken(
        address receiver,
        address market,
        uint256 exactYtIn,
        uint256 minRawTokenOut,
        address[] calldata path,
        bool doPull
    ) internal returns (uint256 netRawTokenOut) {
        (ISuperComposableYield SCY, , ) = IPMarket(market).readTokens();

        uint256 netScyOut = _swapExactYtForScy(address(SCY), market, exactYtIn, 1, doPull);

        netRawTokenOut = _redeemScyToRawToken(
            receiver,
            address(SCY),
            netScyOut,
            minRawTokenOut,
            path,
            false
        );
    }
}
