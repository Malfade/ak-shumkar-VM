/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {isDefined} from 'gmp/utils/identity';
import BlankLink, {type BlankLinkProps} from 'web/components/link/BlankLink';
import useManualURL from 'web/hooks/useManualURL';

export interface ManualLinkProps extends Omit<BlankLinkProps, 'to'> {
  anchor?: string;
  highlight?: string;
  lang?: string;
  page: string;
  searchTerm?: string;
}

const ManualLink = ({
  anchor,
  'data-testid': dataTestId = 'manual-link',
  page,
  searchTerm,
  lang,
  highlight,
  ...props
}: ManualLinkProps) => {
  const manualURL = useManualURL(lang);
  const isLocalManual = manualURL.startsWith('/');

  let url = isLocalManual
    ? `${manualURL}/index.html`
    : `${manualURL}/${page}.html`;

  if (!isLocalManual && page === 'search' && isDefined(searchTerm)) {
    url += '?q=' + searchTerm;
  } else if (!isLocalManual && isDefined(highlight)) {
    url += '?highlight=' + highlight;
  } else if (isDefined(anchor)) {
    url += '#' + anchor;
  } else if (isLocalManual) {
    url += '#' + page;
  }
  return <BlankLink {...props} data-testid={dataTestId} to={url} />;
};

export default ManualLink;
