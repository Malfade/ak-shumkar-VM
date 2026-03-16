/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {useState, useEffect} from 'react';
import {notifications} from '@mantine/notifications';
import {useDispatch} from 'react-redux';
import {useLocation, useNavigate} from 'react-router';
import styled from 'styled-components';
import {ResponseRejection} from 'gmp/http/rejection';
import logger from 'gmp/log';
import {isDefined} from 'gmp/utils/identity';
import {isEmpty} from 'gmp/utils/string';
import Layout from 'web/components/layout/Layout';
import PageTitle from 'web/components/layout/PageTitle';
import useGmp from 'web/hooks/useGmp';
import useTranslation from 'web/hooks/useTranslation';
import useUserIsLoggedIn from 'web/hooks/useUserIsLoggedIn';
import LoginForm from 'web/pages/login/LoginForm';
import {
  setSessionTimeout,
  setUsername,
  setIsLoggedIn,
  setTimezone,
} from 'web/store/usersettings/actions';

const log = logger.getLogger('web.login');
const StyledLayout = styled(Layout)`
  background: radial-gradient(circle at 50% 0%, #1e1e22 0%, #000000 100%);
  flex-direction: column;
  justify-content: center;
  align-items: center;
  height: 100vh;
  position: relative;
  overflow: hidden;

  /* Animated background glow effect */
  &::before {
    content: '';
    position: absolute;
    width: 600px;
    height: 600px;
    background: radial-gradient(
      circle,
      rgba(255, 212, 0, 0.05) 0%,
      transparent 60%
    );
    top: -200px;
    right: -200px;
    animation: pulse 8s ease-in-out infinite alternate;
  }

  @keyframes pulse {
    0% {
      transform: scale(1);
      opacity: 0.5;
    }
    100% {
      transform: scale(1.2);
      opacity: 0.8;
    }
  }
`;

const FooterText = styled.div`
  position: absolute;
  bottom: 2rem;
  color: var(--skysoc-text-muted, #a1a1aa);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  opacity: 0.6;
`;

const isIE11 = () => {
  const match = /Trident\/([\d.]+)/.exec(navigator.userAgent);
  return match ? +match[1] >= 7 : false;
};

const LoginPage: React.FC = () => {
  const gmp = useGmp();
  const navigate = useNavigate();
  const location = useLocation();
  const dispatch = useDispatch();
  const [isLoggedIn] = useUserIsLoggedIn();
  const [error, setError] = useState<Error>();
  const [_] = useTranslation();

  useEffect(() => {
    const checkLoginStatus = async () => {
      // redirect user to main page if he is already logged in
      if (isLoggedIn) {
        try {
          await navigate('/dashboards', {replace: true});
        } catch (error) {
          log.error(error);
        }
      }
    };

    void checkLoginStatus();

    notifications.clean();
  }, [isLoggedIn, navigate]);

  const login = async (username: string, password: string) => {
    try {
      const data = await gmp.login(username, password);

      const {locale, timezone, sessionTimeout} = data;

      gmp.setTimezone(timezone);
      gmp.setLocale(locale);
      dispatch(setSessionTimeout(sessionTimeout));
      dispatch(setUsername(username));
      dispatch(setTimezone(timezone));

      // must be set before changing the location
      dispatch(setIsLoggedIn(true));

      const previousLocation = location.state?.from;
      const previousPath =
        previousLocation &&
        previousLocation.pathname +
          (previousLocation.search ?? '') +
          (previousLocation.hash ?? '');

      if (previousPath && previousPath !== '/login') {
        await navigate(previousPath, {replace: true});
      } else {
        await navigate('/dashboards', {replace: true});
      }
    } catch (error) {
      log.error(error);
      setError(error as Error);
    }

    try {
      const {data: userSettings} = await gmp.user.currentSettings();

      localStorage.setItem(
        'userInterfaceTimeFormat',
        userSettings.userinterfacetimeformat?.value as string,
      );
      localStorage.setItem(
        'userInterfaceDateFormat',
        userSettings.userinterfacedateformat?.value as string,
      );
    } catch (error) {
      log.error(error);
    }
  };

  const handleSubmit = async (username: string, password: string) => {
    await login(username, password);
  };

  const handleGuestLogin = async () => {
    await login(
      gmp.settings.guestUsername ?? 'guest',
      gmp.settings.guestPassword ?? 'guest',
    );
  };

  let message: string | undefined;

  if (error) {
    if (error instanceof ResponseRejection && error.status === 401) {
      message = _('Login Failed. Invalid password or username.');
    } else if (isEmpty(error.message)) {
      message = _('Unknown error on login.');
    } else {
      message = error.message;
    }
  }

  const showGuestLogin =
    isDefined(gmp.settings.guestUsername) &&
    isDefined(gmp.settings.guestPassword);

  const showLogin = !gmp.settings.disableLoginForm;
  const showProtocolInsecure = window.location.protocol !== 'https:';

  return (
    <StyledLayout>
      <PageTitle />
      <LoginForm
        error={message}
        isIE11={isIE11()}
        showGuestLogin={showGuestLogin}
        showLogin={showLogin}
        showProtocolInsecure={showProtocolInsecure}
        onGuestLoginClick={handleGuestLogin}
        onSubmit={handleSubmit}
      />
      <FooterText>SKYSOC VULNERABILITY MANAGEMENT</FooterText>
    </StyledLayout>
  );
};

export default LoginPage;
