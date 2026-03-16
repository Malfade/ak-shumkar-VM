/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import styled from 'styled-components';
import useLanguage from 'web/hooks/useLanguage';
import Theme from 'web/utils/Theme';

const Link = styled.a`
  color: ${Theme.mediumGray};
  font-size: 10px;
  &:link {
    color: ${Theme.mediumGray};
  }
`;

const Footer = styled.footer`
  padding: 2px;
  font-size: 10px;
  text-align: center;
  color: ${Theme.mediumGray};
  margin-top: 10px;
`;

const SkySOCFooter = () => {
  return <Footer>Copyright © 2026 SkySOC</Footer>;
};

export default SkySOCFooter;
