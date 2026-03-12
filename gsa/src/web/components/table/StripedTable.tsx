/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import styled from 'styled-components';
import Table from 'web/components/table/Table';
import Theme from 'web/utils/Theme';

const StripedTable = styled(Table)`
  & th,
  & td {
    padding: 4px 10px;
    border-bottom: 1px solid var(--skysoc-border, ${Theme.lightGray});
  }
  & tfoot tr {
    background: var(--skysoc-bg-card, ${Theme.white});
  }
  & tfoot tr td {
    border-bottom: 1px solid var(--skysoc-border, ${Theme.lightGray});
    padding: 15px 0;
  }
  @media screen {
    & > tbody:nth-of-type(even),
    & > tbody:only-of-type > tr:nth-of-type(even) {
      background: rgba(255, 255, 255, 0.03);
    }
    & > tbody:not(:only-of-type):hover,
    & > tbody:only-of-type > tr:hover {
      background: var(--skysoc-bg-card-hover, ${Theme.lightGray});
    }
  }
`;

StripedTable.displayName = 'StripedTable';

export default StripedTable;
