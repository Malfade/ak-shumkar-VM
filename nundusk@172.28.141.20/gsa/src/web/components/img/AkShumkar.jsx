/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React from 'react';
import GbLogo from '/img/ak-shumkar.png';

const AkShumkarLogo = props => (
  <img alt="Ak Shumkar" {...props} data-testid="greenbone-logo" src={GbLogo} style={{ height: '40px', width: 'auto', ...props.style }} />
);

export default AkShumkarLogo;
