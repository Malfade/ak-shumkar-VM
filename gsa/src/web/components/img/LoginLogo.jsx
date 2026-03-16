/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React from 'react';
import styled from 'styled-components';
import Img from 'web/components/img/Img';
import useGmp from 'web/hooks/useGmp';
import useTranslation from 'web/hooks/useTranslation';

const SKYSOC_LOGO = 'skysoc-logo.fc88ba28.png';
const SKYSOC_SCAN_LOGO = 'skysoc-logo.fc88ba28.png';

const Image = styled(Img)`
  display: flex;
  max-width: 100%;
  height: auto;
  filter: drop-shadow(0 4px 8px rgba(0, 0, 0, 0.5));
`;

const LoginLogo = ({width}) => {
  const [_] = useTranslation();
  const gmp = useGmp();
  const loginTopLogo = gmp?.settings?.vendorLabel
    ? SKYSOC_SCAN_LOGO
    : SKYSOC_LOGO;

  return (
    <Image
      key="login-logo"
      alt={_('SkySOC')}
      data-testid="greenbone-login-logo"
      src={loginTopLogo}
      style={{width: width || '100%'}}
    />
  );
};

export default LoginLogo;
