// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WebsiteBuyer} from "src/WebsiteBuyer.sol";

/// @dev Builds the brief's job.open template (objective prefix, skill, host) with words and owner slots.
library SiteTemplate {
    function parts(string memory prefix, string memory skill, bool host) internal pure returns (bytes[] memory p) {
        p = new bytes[](3);
        p[0] = abi.encodePacked('{"objective":"', prefix);
        p[1] = abi.encodePacked('","skill":"', skill, '","host":', host ? "true" : "false", ',"owner":"');
        p[2] = '"}';
    }

    function slots() internal pure returns (WebsiteBuyer.Slot[] memory s) {
        s = new WebsiteBuyer.Slot[](2);
        s[0] = WebsiteBuyer.Slot.Words;
        s[1] = WebsiteBuyer.Slot.Caller;
    }
}
