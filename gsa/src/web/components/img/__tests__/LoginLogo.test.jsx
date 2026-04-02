/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {describe, test, expect} from '@gsa/testing';
import {rendererWith} from 'web/testing';
import AkShumkarLoginLogo from 'web/components/img/LoginLogo';

describe('AkShumkarLogo tests', () => {
  test('should render', () => {
    const {render} = rendererWith({
      gmp: {settings: {}},
    });
    const {element} = render(<AkShumkarLoginLogo />);

    expect(element).toHaveAttribute('alt', 'Ak Shumkar AG');
    expect(element).toHaveAttribute('data-testid', 'greenbone-login-logo');
    expect(element).toHaveAttribute('src', '/img/openvasHorizontal.svg');
  });

  test('should render scan logo when vendorLabel is set', () => {
    const {render} = rendererWith({
      gmp: {settings: {vendorLabel: 'test'}},
    });
    const {element} = render(<AkShumkarLoginLogo />);

    expect(element).toHaveAttribute('alt', 'Ak Shumkar AG');
    expect(element).toHaveAttribute('data-testid', 'greenbone-login-logo');
    expect(element).toHaveAttribute('src', '/img/openvasHorizontal-scan.svg');
  });
});
