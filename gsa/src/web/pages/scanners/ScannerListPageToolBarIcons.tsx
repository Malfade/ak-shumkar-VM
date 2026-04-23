/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {NewIcon} from 'web/components/icon';
import ManualIcon from 'web/components/icon/ManualIcon';
import IconDivider from 'web/components/layout/IconDivider';
import useTranslation from 'web/hooks/useTranslation';

interface ScannerListPageToolBarIconsProps {
  onScannerCreateClick: () => void;
}

const ScannerListPageToolBarIcons = ({
  onScannerCreateClick,
}: ScannerListPageToolBarIconsProps) => {
  const [_] = useTranslation();
  return (
    <IconDivider>
      <ManualIcon
        anchor="managing-scanners"
        page="scanning"
        title={_('Help: Scanners')}
      />
      <NewIcon
        title={_('New Scanner')}
        onClick={() => onScannerCreateClick && onScannerCreateClick()}
      />
    </IconDivider>
  );
};

export default ScannerListPageToolBarIcons;
