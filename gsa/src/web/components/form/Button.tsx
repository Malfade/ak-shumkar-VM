/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import React, { type ReactNode, type MouseEvent } from 'react';
import { Button as OpenSightButton } from '@greenbone/ui-lib';
import useValueChange from 'web/components/form/useValueChange';

interface ButtonProps {
  title?: string;
  children?: ReactNode;
  convert?: (value: unknown) => unknown;
  disabled?: boolean;
  isLoading?: boolean;
  name?: string;
  value?: string | number | string[] | undefined;
  onClick?: (value: unknown) => void;
  [key: string]: unknown;
}

const Button: React.FC<ButtonProps> = ({
  title,
  children = title,
  convert,
  disabled,
  isLoading = false,
  name,
  value,
  onClick,
  ...other
}) => {
  const handleChange = useValueChange({
    disabled,
    onChange: onClick,
    convert,
    name,
  });

  const handleClick = (event: MouseEvent<HTMLButtonElement>) => {
    if (name !== undefined || convert !== undefined || value !== undefined) {
      // Behave like an input that emits value/name
      // Ensure event is defined before accessing it in handleChange
      if (event && event.target) {
        handleChange(event as unknown as React.ChangeEvent<HTMLInputElement>);
      } else if (onClick) {
        onClick(value);
      }
    } else if (onClick) {
      // Standard button click
      onClick(event);
    }
  };

  return (
    <div className={other.className as string} style={other.style as React.CSSProperties}>
      <OpenSightButton
        data-testid="opensight-button"
        {...other}
        className={undefined} // Remove className from sub-component to avoid double styling
        disabled={disabled}
        loading={isLoading}
        name={name}
        value={value}
        onClick={handleClick}
      >
        {children}
      </OpenSightButton>
    </div>
  );
};

export default Button;
