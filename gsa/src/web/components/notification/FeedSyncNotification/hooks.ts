/* SPDX-FileCopyrightText: 2024 Greenbone AG
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import {useEffect, useState} from 'react';
import {useDispatch, useSelector} from 'react-redux';
import type Rejection from 'gmp/http/rejection';
import useGmp from 'web/hooks/useGmp';
import {setSyncStatus, setError} from 'web/store/feedStatus/actions';

interface FeedStatus {
  isSyncing?: boolean;
  error?: string;
}

/** Poll while “syncing” can block scans; slow down when feeds are idle. */
const POLL_MS_FEED_SYNC_ACTIVE = 45 * 1000;
const POLL_MS_FEED_SYNC_IDLE = 5 * 60 * 1000;
const THIRTY_SECONDS = 30 * 1000;

/**
 * Custom hook to check feed sync for scan-blocking feeds (NVT + GVMD_DATA only).
 * Polls more often when syncing so the banner clears shortly after gvmd finishes.
 */
export const useFeedSyncStatus = () => {
  const dispatch = useDispatch();
  const gmp = useGmp();

  useEffect(() => {
    let cancelled = false;
    let timeoutId: ReturnType<typeof setTimeout>;

    const schedule = (delayMs: number) => {
      timeoutId = setTimeout(() => void tick(), delayMs);
    };

    const tick = async () => {
      if (cancelled) {
        return;
      }
      let nextSyncing = false;
      try {
        const response = await gmp.feedstatus.checkFeedSync();
        nextSyncing = response.isSyncing;
        dispatch(setSyncStatus(response.isSyncing));
      } catch (error) {
        dispatch(setError((error as Error | Rejection).message));
      }
      if (!cancelled) {
        schedule(
          nextSyncing ? POLL_MS_FEED_SYNC_ACTIVE : POLL_MS_FEED_SYNC_IDLE,
        );
      }
    };

    void tick();

    return () => {
      cancelled = true;
      clearTimeout(timeoutId);
    };
  }, [dispatch, gmp]);
};

/**
 * Hook to manage the feed sync dialog state.
 *
 * @returns {[boolean, React.Dispatch<React.SetStateAction<boolean>>, { isSyncing: boolean, error: string }]}
 * An array containing the dialog state, a function to set the dialog state, and the feed status.
 */

export const useFeedSyncDialog = (): [
  boolean,
  React.Dispatch<React.SetStateAction<boolean>>,
  FeedStatus,
] => {
  const feedStatus = useSelector<{feedStatus: FeedStatus}, FeedStatus>(
    state => state.feedStatus,
  );

  const [isFeedSyncDialogOpened, setIsFeedSyncDialogOpened] = useState(false);

  useEffect(() => {
    if (feedStatus.isSyncing || feedStatus.error) {
      setIsFeedSyncDialogOpened(true);

      const timer = setTimeout(() => {
        setIsFeedSyncDialogOpened(false);
      }, THIRTY_SECONDS);

      return () => clearTimeout(timer);
    }
  }, [feedStatus.isSyncing, feedStatus.error]);

  return [isFeedSyncDialogOpened, setIsFeedSyncDialogOpened, feedStatus];
};
