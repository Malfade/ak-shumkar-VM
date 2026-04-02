/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {useState} from 'react';
import {ActionIcon} from '@mantine/core';
import {FlagDeIcon, FlagEnIcon} from '@greenbone/ui-lib';
import {DEFAULT_LANGUAGE} from 'gmp/locale/lang';
import useLanguage from 'web/hooks/useLanguage';
import useTranslation from 'web/hooks/useTranslation';
import FlagRuIcon from 'web/components/icon/FlagRuIcon';
import FlagKgIcon from 'web/components/icon/FlagKgIcon';

type LanguageCode = 'en' | 'de' | 'ru' | 'kg';

interface Languages {
  EN: LanguageCode;
  DE: LanguageCode;
  RU: LanguageCode;
  KG: LanguageCode;
}

const LANGUAGES: Languages = {
  EN: DEFAULT_LANGUAGE as LanguageCode,
  DE: 'de',
  RU: 'ru',
  KG: 'kg',
};

const getNextLanguage = (language: LanguageCode): LanguageCode => {
  if (language === LANGUAGES.EN) {
    return LANGUAGES.DE;
  }
  if (language === LANGUAGES.DE) {
    return LANGUAGES.RU;
  }
  if (language === LANGUAGES.RU) {
    return LANGUAGES.KG;
  }
  return LANGUAGES.EN;
};

const LanguageSwitch: React.FC = () => {
  const [language, setLanguage] = useLanguage();
  const [_] = useTranslation();
  const [isChangingLanguage, setIsChangingLanguage] = useState<boolean>(false);

  const langCode = language as LanguageCode;
  const nextLanguage: LanguageCode = getNextLanguage(langCode);
  const titles: Record<LanguageCode, string> = {
    en: _('Switch language to English'),
    de: _('Switch language to German'),
    ru: _('Switch language to Russian'),
    kg: _('Switch language to Kyrgyz'),
  };

  const handleLanguageChange = async (): Promise<void> => {
    if (isChangingLanguage) {
      return;
    }

    try {
      setIsChangingLanguage(true);
      await setLanguage(nextLanguage);
    } catch (error) {
      throw new Error(error instanceof Error ? error.message : String(error));
    } finally {
      setIsChangingLanguage(false);
    }
  };

  const renderFlag = () => {
    switch (langCode) {
      case LANGUAGES.DE:
        return <FlagDeIcon />;
      case LANGUAGES.RU:
        return <FlagRuIcon />;
      case LANGUAGES.KG:
        return <FlagKgIcon />;
      default:
        return <FlagEnIcon />;
    }
  };

  return (
    <ActionIcon
      color="neutral.0"
      disabled={isChangingLanguage}
      title={titles[nextLanguage]}
      variant="transparent"
      onClick={handleLanguageChange}
    >
      {renderFlag()}
    </ActionIcon>
  );
};

export default LanguageSwitch;
