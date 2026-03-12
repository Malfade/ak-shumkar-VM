/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import { createGlobalStyle } from 'styled-components';
import Theme from 'web/utils/Theme';

const GlobalStyles = createGlobalStyle`
  html {
    box-sizing: border-box;
    background-color: var(--skysoc-bg-base, #1A1A1C);
  }

  *, *:before, *:after {
    box-sizing: inherit;
  }

  body {
    margin: 0;
    font-family: ${Theme.Font.default};
    font-size: ${Theme.Font.defaultSize};
    color: var(--skysoc-text-primary, #FFFFFF);
    background-color: var(--skysoc-bg-base, #1A1A1C);
  }

  a:link {
    color: var(--skysoc-link, #4A80FF);
    text-decoration: none;
  }

  a:visited {
    color: var(--skysoc-link, #4A80FF);
  }

  a:hover, a:focus {
    color: var(--skysoc-link-hover, #6FA3FF);
    text-decoration: underline;
  }

  pre {
    white-space: pre-wrap;
    word-wrap: break-word;
  }

  img {
    border: 0;
  }

  svg {
    overflow: hidden;
  }

  h1 {
    font-size: 20px;
    color: var(--skysoc-text-primary, #FFFFFF);
  }

  h2 {
    font-size: 18px;
    color: var(--skysoc-text-primary, #FFFFFF);
  }

  h3 {
    font-size: 16px;
    color: var(--skysoc-text-primary, #FFFFFF);
  }

  h4 {
    font-size: 14px;
    margin-bottom: 0;
    color: var(--skysoc-text-primary, #FFFFFF);
  }

  p {
    margin: 0 0 10px;
    color: var(--skysoc-text-primary, #FFFFFF);
  }

  .axis-label {
    fill: var(--skysoc-text-muted, #A1A1AA)
  }

  .axis-line, .axis-tick line {
    shape-rendering: 'crispEdges';
    stroke: var(--skysoc-border, #3F3F46);
    stroke-width: 0.99;
  }

  .mantine-Notifications-root.width-before-scroll-bar[data-position='top-right'] {
    top: calc(var(--header-height) + var(--mantine-spacing-md));
  }
`;

export default GlobalStyles;
