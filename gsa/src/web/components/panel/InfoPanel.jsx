/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React from 'react';
import styled from 'styled-components';
import {isDefined} from 'gmp/utils/identity';
import {XIcon} from 'web/components/icon';
import Layout from 'web/components/layout/Layout';
import PropTypes from 'web/utils/PropTypes';
import Theme from 'web/utils/Theme';
const Panel = styled(Layout)`
  background-color: rgba(39, 39, 42, 0.7);
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  margin-top: ${props => (props.$noMargin ? '0px' : '10px')};
  border-radius: 12px;
  overflow: hidden;
`;

const Heading = styled.div`
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  min-height: 40px;
  background-color: ${props =>
    props.$isWarning ? 'rgba(239, 68, 68, 0.2)' : 'rgba(74, 128, 255, 0.15)'};
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  color: ${props => (props.$isWarning ? '#F87171' : '#FFFFFF')};
  font-weight: 600;
  font-size: 14px;
`;

const Footer = styled.div`
  display: flex;
  padding: 10px 16px;
  background-color: rgba(255, 255, 255, 0.05);
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  min-height: 35px;
`;

const Body = styled.div`
  display: flex;
  flex-direction: column;
  padding: 16px;
  flex-grow: 1;
  color: rgba(255, 255, 255, 0.9);
  font-size: 14px;
  line-height: 1.5;

  p {
    margin: 0;
  }
`;

const InfoPanel = ({
  heading,
  footer,
  isWarning = false,
  children,
  onCloseClick,
  noMargin,
  ...props
}) => {
  return (
    <Panel
      $isWarning={isWarning}
      $noMargin={noMargin}
      align={['start', 'stretch']}
      flex="column"
      {...props}
    >
      {heading && (
        <Heading $isWarning={isWarning} data-testid="infopanel-heading">
          {heading}
          {isDefined(onCloseClick) && (
            <XIcon
              color="#A1A1AA"
              data-testid="panel-close-button"
              size="medium"
              variant="transparent"
              onClick={onCloseClick}
            />
          )}
        </Heading>
      )}
      {children && <Body>{children}</Body>}
      {footer && <Footer>{footer}</Footer>}
    </Panel>
  );
};

InfoPanel.propTypes = {
  children: PropTypes.element,
  noMargin: PropTypes.bool,
  footer: PropTypes.oneOfType([PropTypes.element, PropTypes.string]),
  heading: PropTypes.oneOfType([PropTypes.element, PropTypes.string]),
  isWarning: PropTypes.bool,
  onCloseClick: PropTypes.func,
};

export default InfoPanel;
