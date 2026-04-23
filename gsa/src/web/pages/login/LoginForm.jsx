/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React from 'react';
import styled from 'styled-components';
import { KeyCode } from 'gmp/utils/event';
import { isDefined } from 'gmp/utils/identity';
import ErrorContainer from 'web/components/error/ErrorContainer';
import Button from 'web/components/form/Button';
import FormGroup from 'web/components/form/FormGroup';
import PasswordField from 'web/components/form/PasswordField';
import TextField from 'web/components/form/TextField';
import useFormValues from 'web/components/form/useFormValues';
import Img from 'web/components/img/Img';
import GlitchLogo from 'web/components/img/GlitchLogo';
import useTranslation from 'web/hooks/useTranslation';
import PropTypes from 'web/utils/PropTypes';

/* Ak Shumkar Glassmorphic Panel */
const GlassPanel = styled.div`
  background: rgba(39, 39, 42, 0.4);
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  border: 1px solid rgba(255, 255, 255, 0.08);
  box-shadow:
    0 24px 40px rgba(0, 0, 0, 0.5),
    inset 0 1px 0 rgba(255, 255, 255, 0.1);
  border-radius: 20px;
  padding: 3.5rem;
  width: 26rem;
  z-index: 10;
  display: flex;
  flex-direction: column;
  transition:
    transform 0.3s ease,
    box-shadow 0.3s ease;

  &:hover {
    box-shadow:
      0 30px 60px rgba(0, 0, 0, 0.6),
      inset 0 1px 0 rgba(255, 255, 255, 0.15);
  }
`;

const Panel = styled.div`
  margin: 5px auto;
  padding-bottom: 10px;
  font-size: 9pt;
  padding: 10px;
  margin-bottom: 10px;
`;

const StyledWarningError = styled.p`
  color: var(--ak-shumkar-critical, #ef4444);
  font-weight: 600;
  text-align: center;
  margin: 10px 0;
`;

const StyledErrorContainer = styled(ErrorContainer)`
  margin: 0 0 1.5rem 0;
  font-size: 14px;
  border-radius: 8px;
  background: rgba(239, 68, 68, 0.1);
  border: 1px solid rgba(239, 68, 68, 0.2);
  color: var(--ak-shumkar-critical, #ef4444);
  padding: 1rem;
`;

const StyledPanel = styled(Panel)`
  margin-top: 20px;
`;

const H1 = styled.h1`
  font-size: 24px;
  font-weight: 600;
  color: var(--ak-shumkar-text-primary, #ffffff);
  margin-bottom: 2rem;
  text-align: center;
  letter-spacing: -0.02em;
`;

const LogoContainer = styled.div`
  margin-bottom: 2.5rem;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-direction: column;
  gap: 1.5rem;
`;

const EagleLogo = styled(Img)`
  width: 120px;
  height: auto;
  filter: drop-shadow(0 4px 8px rgba(0, 0, 0, 0.5));
`;

const LogoText = styled.div`
  display: flex;
  align-items: center;
  justify-content: center;
`;

const FieldWrapper = styled.div`
  margin-bottom: 1.5rem;
`;

const FullWidthButton = styled(Button)`
  width: 100%;
  margin-top: 1rem;
  height: 48px !important;
  min-height: 48px !important;
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  padding: 0 24px !important;
  font-size: 16px !important;
  line-height: 1 !important;
  overflow: visible !important;
`;

const LoginForm = ({
  error,
  showGuestLogin = false,
  showLogin = true,
  showProtocolInsecure = false,
  isIE11 = false,
  onGuestLoginClick,
  onSubmit,
}) => {
  const [_] = useTranslation();
  const [{ username, password }, handleValueChange] = useFormValues({
    username: '',
    password: '',
  });

  const handleSubmit = () => {
    if (isDefined(onSubmit)) {
      onSubmit(username, password);
    }
  };

  const handleKeyDown = event => {
    if (event.keyCode === KeyCode.ENTER) {
      handleSubmit();
    }
  };

  return (
    <GlassPanel>
      <LogoContainer>
        <EagleLogo
          src="ak-shumkar.png"
          alt="AK-SHUMKAR Eagle Logo"
        />
        <LogoText>
          <GlitchLogo text="AKSHUMKAR" size="2.4rem" />
        </LogoText>
      </LogoContainer>

      {showProtocolInsecure && (
        <StyledPanel data-testid="protocol-insecure">
          <StyledWarningError>
            {_('Warning: Connection unencrypted')}
          </StyledWarningError>
          <p style={{ color: 'var(--ak-shumkar-text-muted)', fontSize: '13px' }}>
            {_(
              'The connection to this web application is not encrypted, allowing ' +
              'anyone listening to the traffic to steal your credentials.',
            )}
          </p>
        </StyledPanel>
      )}

      {isIE11 && (
        <Panel data-testid="IE11">
          <StyledWarningError>
            {_('Warning: You are using IE11')}
          </StyledWarningError>
          <p style={{ color: 'var(--ak-shumkar-text-muted)' }}>
            {_(
              'You are using Internet Explorer 11. This browser is not supported anymore. Please use an up-to-date alternative.',
            )}
          </p>
        </Panel>
      )}

      {isDefined(error) && (
        <StyledErrorContainer data-testid="error">{error}</StyledErrorContainer>
      )}

      {showLogin && !isIE11 && (
        <FormGroup>
          <H1>{_('Sign in to your account')}</H1>
          <FieldWrapper>
            <TextField
              autoComplete="username"
              autoFocus={true}
              name="username"
              placeholder={_('Username')}
              tabIndex="1"
              title={_('Username')}
              value={username}
              onChange={handleValueChange}
            />
          </FieldWrapper>
          <FieldWrapper>
            <PasswordField
              autoComplete="current-password"
              name="password"
              placeholder={_('Password')}
              title={_('Password')}
              value={password}
              onChange={handleValueChange}
              onKeyDown={handleKeyDown}
            />
          </FieldWrapper>
          <FullWidthButton data-testid="login-button" onClick={handleSubmit}>
            {_('Sign in')}
          </FullWidthButton>
        </FormGroup>
      )}

      {showGuestLogin && (
        <FormGroup data-testid="guest-login" style={{ marginTop: '1rem' }}>
          <FullWidthButton
            data-testid="guest-login-button"
            onClick={onGuestLoginClick}
            variant="outline"
          >
            {_('Sign in as Guest')}
          </FullWidthButton>
        </FormGroup>
      )}
    </GlassPanel>
  );
};

LoginForm.propTypes = {
  error: PropTypes.string,
  isIE11: PropTypes.bool,
  showGuestLogin: PropTypes.bool,
  showLogin: PropTypes.bool,
  showProtocolInsecure: PropTypes.bool,
  onGuestLoginClick: PropTypes.func.isRequired,
  onSubmit: PropTypes.func.isRequired,
};

export default LoginForm;
