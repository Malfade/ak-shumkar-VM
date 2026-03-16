/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import type React from 'react';

export const FlagKgIcon: React.FC<React.SVGProps<SVGSVGElement>> = props => (
  <svg viewBox="0 0 1000 600" xmlns="http://www.w3.org/2000/svg" {...props}>
    <rect width="1000" height="600" fill="#e62020" />
    <path
      d="M500 100c-110.5 0-200 89.5-200 200s89.5 200 200 200 200-89.5 200-200-89.5-200-200-200zm0 30c93.9 0 170 76.1 170 170s-76.1 170-170 170-170-76.1-170-170 76.1-170 170-170z"
      fill="#ffda00"
    />
    <path
      d="M500 150l12 110-100-30 100-30-12 110zM500 450l-12-110 100 30-100 30 12-110zM350 300l110 12-30-100-30 100 110-12zM650 300l-110-12 30 100 30-100-110 12z"
      fill="#ffda00"
    />
  </svg>
);

export default FlagKgIcon;
