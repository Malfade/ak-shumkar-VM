/* SPDX-FileCopyrightText: 2025 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {DEFAULT_MANUAL_URL} from 'gmp/settings';
import {isDefined} from 'gmp/utils/identity';
import useGmp from 'web/hooks/useGmp';
import useLanguage from 'web/hooks/useLanguage';

const DEFAULT_LANGUAGE_MAPPING = {
  de: 'ru',
  en: 'ru',
  ru: 'ru',
};

const DEFAULT_LANGUAGE_PATH = 'ru';

const normalizeManualUrl = (manualUrl: string) => {
  if (manualUrl === '/manual' || manualUrl === '/manual/') {
    return '/manual/ak-shumkar';
  }

  if (manualUrl.startsWith('/')) {
    if (manualUrl.startsWith('/manual/') && !manualUrl.includes('/ak-shumkar')) {
      return manualUrl.replace('/manual/', '/manual/ak-shumkar/');
    }
    return manualUrl;
  }

  try {
    const url = new URL(manualUrl, global.location.origin);
    if (
      url.hostname === global.location.hostname &&
      url.pathname.startsWith('/manual')
    ) {
      if (url.pathname === '/manual' || url.pathname === '/manual/') {
        return '/manual/ak-shumkar';
      }
      if (
        url.pathname.startsWith('/manual/') &&
        !url.pathname.includes('/ak-shumkar')
      ) {
        return url.pathname.replace('/manual/', '/manual/ak-shumkar/');
      }
      return url.pathname;
    }
  } catch {
    // Keep original value if URL parsing fails.
  }

  return manualUrl;
};

const getLanguagePath = (
  locale: string | undefined,
  languageMapping: Record<string, string>,
) => {
  if (!isDefined(locale)) {
    return DEFAULT_LANGUAGE_PATH;
  }

  const code = locale.slice(0, 2);
  const path = languageMapping[code];

  return isDefined(path) ? path : DEFAULT_LANGUAGE_PATH;
};

const useManualURL = (locale?: string) => {
  const [language] = useLanguage();
  const gmp = useGmp();
  const {
    manualUrl = DEFAULT_MANUAL_URL,
    manualLanguageMapping = DEFAULT_LANGUAGE_MAPPING,
  } = gmp.settings;

  const normalizedManualUrl = normalizeManualUrl(manualUrl);
  const baseUrl = normalizedManualUrl.endsWith('/')
    ? normalizedManualUrl
    : `${normalizedManualUrl}/`;
  const languagePath = getLanguagePath(
    locale || language,
    manualLanguageMapping,
  );

  const localizedBase = `${baseUrl}${languagePath}`;
  const localizedUrl = localizedBase.endsWith('/')
    ? localizedBase
    : `${localizedBase}/`;

  return `${localizedUrl}index.html`;
};

export default useManualURL;
