/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import type React from 'react';

export const FlagRuIcon: React.FC<React.SVGProps<SVGSVGElement>> = props => (
  <svg viewBox="0 0 900 600" xmlns="http://www.w3.org/2000/svg" {...props}>
    <rect width="900" height="600" fill="#fff" />
    <rect width="900" height="400" y="200" fill="#0039a6" />
    <rect width="900" height="200" y="400" fill="#d52b1e" />
  </svg>
);

export default FlagRuIcon;
