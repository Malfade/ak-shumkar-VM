/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {describe, test, expect} from '@gsa/testing';
import {render} from 'web/testing';
import AkShumkarLogo from 'web/components/img/AkShumkar';

describe('AkShumkarLogo tests', () => {
  test('should render', () => {
    const {element} = render(<AkShumkarLogo />);

    expect(element).toHaveAttribute('alt', 'Ak Shumkar');
    expect(element).toHaveAttribute('data-testid', 'greenbone-logo');
    expect(element).toHaveAttribute('src');
  });
});
