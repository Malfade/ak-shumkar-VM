/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

interface ThemeLayer {
  menu: number;
  aboveAll: number;
  onTop: number;
  belowAll: number;
  higher: number;
  default: number;
}

interface ThemeFont {
  default: string;
  dialog: string;
  defaultSize: string;
}

interface ThemeInterface {
  lightGreen: string;
  green: string;
  lightGray: string;
  mediumDarkGray: string;
  mediumGray: string;
  darkGray: string;
  white: string;
  dialogGray: string;
  inputBorderGray: string;
  black: string;
  loginButtonGray: string;
  loginButtonHover: string;
  lightRed: string;
  mediumLightRed: string;
  warningRed: string;
  darkRed: string;
  errorRed: string;
  complianceYes: string;
  complianceNo: string;
  complianceIncomplete: string;
  complianceUndefined: string;
  lightBlue: string;
  mediumBlue: string;
  blue: string;
  severityLowBlue: string;
  severityWarnYellow: string;
  severityClassLog: string;
  severityClassLow: string;
  severityClassMedium: string;
  severityClassHigh: string;
  severityClassCritical: string;
  statusNewGreen: string;
  statusRunGreen: string;
  paleGreen: string;
  darkGreen: string;
  darkGreenTransparent: string;
  Layers: ThemeLayer;
  Font: ThemeFont;
}

const Theme: ThemeInterface = {
  /* SkySOC dark theme colors */
  lightGreen: '#4ADE80',
  green: '#22C55E',

  lightGray: '#3F3F46',    // disabled inputs
  mediumDarkGray: '#52525B',
  mediumGray: '#71717A',
  darkGray: '#A1A1AA',

  /* SkySOC core */
  white: '#FFFFFF',
  dialogGray: '#27272A',   // dialog and dashboard display backgrounds
  inputBorderGray: '#3F3F46',  // form field borders
  black: '#1A1A1C',        // base background (not pure black)
  loginButtonGray: '#FFD400',  // primary action — Beeline yellow
  loginButtonHover: '#E6BF00', // hover state for yellow buttons

  lightRed: '#2D1B1B',       // dialog errors background
  mediumLightRed: '#7F1D1D', // dialog errors border
  warningRed: '#EF4444',     // warning font color
  darkRed: '#DC2626',        // dialog errors font
  errorRed: '#C83814',       // progressbar error

  complianceYes: '#22C55E',
  complianceNo: '#EF4444',
  complianceIncomplete: '#F59E0B',
  complianceUndefined: '#52525B',

  lightBlue: '#1E3A5F',      // info panel and dashboard hover
  mediumBlue: '#3B82F6',     // active/hovered items in Select
  blue: '#4A80FF',           // links
  severityLowBlue: '#60A5FA',

  severityWarnYellow: '#FFD400',

  severityClassLog: '#52525B',
  severityClassLow: '#3B82F6',
  severityClassMedium: '#F59E0B',
  severityClassHigh: '#EF4444',
  severityClassCritical: '#991B1B',

  statusNewGreen: '#84CC16',
  statusRunGreen: '#22C55E',

  paleGreen: '#84CC16',

  darkGreen: '#14532D',
  darkGreenTransparent: 'rgba(20, 83, 45, 0.8)',

  Layers: {
    menu: 600,
    aboveAll: 500,
    onTop: 100,
    belowAll: -100,
    higher: 1,
    default: 0,
  },

  Font: {
    default: "'Poppins', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
    dialog: "'Poppins', Verdana, Arial, sans-serif",
    defaultSize: 'var(--mantine-font-size-md)',
  },
};

export default Theme;
