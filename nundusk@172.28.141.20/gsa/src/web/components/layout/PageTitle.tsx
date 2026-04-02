/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import { useEffect } from 'react';
import { isDefined } from 'gmp/utils/identity';
import useGmp from 'web/hooks/useGmp';
import { applianceTitle } from 'web/utils/appliance-data';

interface PageTitleProps {
  title?: string;
}

const PageTitle = ({ title: pageTitle }: PageTitleProps) => {
  const gmp = useGmp();
  const vendorLabel = gmp?.settings?.vendorLabel ?? 'defaultVendorLabel';

  const vendorTitle = gmp?.settings?.vendorTitle;

  const title = (vendorTitle ?? applianceTitle[vendorLabel] ?? 'Ak Shumkar VM').replace('OPENVAS', 'Ak Shumkar VM');

  useEffect(() => {
    const finalTitle = title.includes('Ak Shumkar') ? title : 'Ak Shumkar VM';
    if (isDefined(pageTitle)) {
      document.title = finalTitle + ' - ' + pageTitle;
    } else {
      document.title = finalTitle;
    }

    return () => {
      document.title = finalTitle;
    };
  }, [title, pageTitle]);

  return null;
};

export default PageTitle;
