/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React from 'react';
import styled, { keyframes } from 'styled-components';

/* ──────────────────────────────────────────────
 * Glitch animation keyframes
 * Two independent offset layers (red / cyan offset)
 * mimicking analog-signal interference / CRT noise
 * ────────────────────────────────────────────── */

const glitch1 = keyframes`
  0%   { clip-path: inset(40% 0 50% 0); transform: translate(-4px, 0); }
  10%  { clip-path: inset(10% 0 80% 0); transform: translate(4px,  0); }
  20%  { clip-path: inset(60% 0 20% 0); transform: translate(-2px, 0); }
  30%  { clip-path: inset(80% 0  5% 0); transform: translate(3px,  0); }
  40%  { clip-path: inset(20% 0 65% 0); transform: translate(-3px, 0); }
  50%  { clip-path: inset(50% 0 30% 0); transform: translate(2px,  0); }
  60%  { clip-path: inset( 5% 0 85% 0); transform: translate(-4px, 0); }
  70%  { clip-path: inset(35% 0 45% 0); transform: translate(4px,  0); }
  80%  { clip-path: inset(75% 0 10% 0); transform: translate(-2px, 0); }
  90%  { clip-path: inset(15% 0 70% 0); transform: translate(3px,  0); }
  100% { clip-path: inset(40% 0 50% 0); transform: translate(-4px, 0); }
`;

const glitch2 = keyframes`
  0%   { clip-path: inset(55% 0 30% 0); transform: translate(3px,  0); }
  15%  { clip-path: inset( 5% 0 75% 0); transform: translate(-3px, 0); }
  25%  { clip-path: inset(70% 0 15% 0); transform: translate(4px,  0); }
  35%  { clip-path: inset(25% 0 60% 0); transform: translate(-4px, 0); }
  45%  { clip-path: inset(85% 0  3% 0); transform: translate(2px,  0); }
  55%  { clip-path: inset(40% 0 45% 0); transform: translate(-2px, 0); }
  65%  { clip-path: inset(10% 0 80% 0); transform: translate(4px,  0); }
  75%  { clip-path: inset(60% 0 25% 0); transform: translate(-3px, 0); }
  85%  { clip-path: inset(30% 0 55% 0); transform: translate(3px,  0); }
  95%  { clip-path: inset(50% 0 35% 0); transform: translate(-4px, 0); }
  100% { clip-path: inset(55% 0 30% 0); transform: translate(3px,  0); }
`;

/* Subtle constant flicker on the base text */
const flicker = keyframes`
  0%,  95%, 100% { opacity: 1; }
  96%             { opacity: 0.85; }
  97%             { opacity: 1; }
  98%             { opacity: 0.7; }
  99%             { opacity: 1; }
`;

/* ──────────────────────────────────────────────
 * Styled components
 * ────────────────────────────────────────────── */

const GlitchWrapper = styled.div`
  position: relative;
  display: inline-block;
  user-select: none;
`;

const GlitchText = styled.span`
  font-family: 'Langar', 'Poppins', sans-serif;
  font-size: ${({ $size }) => $size || '2.8rem'};
  font-weight: 400;
  letter-spacing: 0.12em;
  color: #ffffff;
  text-transform: uppercase;
  text-shadow:
    0 0 10px rgba(255, 212, 0, 0.4),
    0 0 30px rgba(255, 212, 0, 0.15);
  animation: ${flicker} 6s linear infinite;
  display: block;
  position: relative;

  /* Red layer */
  &::before {
    content: attr(data-text);
    font-family: inherit;
    font-size: inherit;
    font-weight: inherit;
    letter-spacing: inherit;
    position: absolute;
    inset: 0;
    color: #ff3c3c;
    text-shadow: none;
    animation: ${glitch1} 3.5s steps(1) infinite;
    opacity: 0.8;
    pointer-events: none;
  }

  /* Cyan layer */
  &::after {
    content: attr(data-text);
    font-family: inherit;
    font-size: inherit;
    font-weight: inherit;
    letter-spacing: inherit;
    position: absolute;
    inset: 0;
    color: #00e5ff;
    text-shadow: none;
    animation: ${glitch2} 4.2s steps(1) infinite;
    opacity: 0.7;
    pointer-events: none;
  }
`;

/* ──────────────────────────────────────────────
 * Component
 * ────────────────────────────────────────────── */

const GlitchLogo = ({ text = 'AKSHUMKAR', size }) => (
    <GlitchWrapper>
        <GlitchText data-text={text} $size={size}>
            {text}
        </GlitchText>
    </GlitchWrapper>
);

export default GlitchLogo;
