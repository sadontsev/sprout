import { useEffect, useRef, useState } from 'react';
import type { BambuddyClient } from '../api/bambuddyClient';
import type { PrinterStatus } from '../api/types';

/** Pure: extract a PrinterStatus from a raw WS frame for our printer, else null. */
export function parseWsMessage(raw: string, printerId: number): PrinterStatus | null {
  try {
    const m = JSON.parse(raw);
    if (m?.type === 'printer_status' && m.printer_id === printerId && m.data) {
      return m.data as PrinterStatus;
    }
    return null;
  } catch {
    return null;
  }
}

const POLL_MS = 3000;

/** Live printer status via WebSocket, falling back to REST polling on disconnect. */
export function usePrinterStatus(client: BambuddyClient, printerId: number) {
  const [status, setStatus] = useState<PrinterStatus | null>(null);
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let cancelled = false;
    let pollTimer: ReturnType<typeof setInterval> | undefined;

    function startPolling() {
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(async () => {
        try {
          const s = await client.getStatus(printerId);
          if (!cancelled) setStatus(s);
        } catch {
          /* keep polling */
        }
      }, POLL_MS);
    }

    async function connect() {
      try {
        const token = await client.mintWsToken();
        if (cancelled) return;
        const ws = new WebSocket(`${client.wsBaseUrl}/api/v1/ws?token=${token}`);
        wsRef.current = ws;
        ws.onopen = () => {
          if (!cancelled) setConnected(true);
        };
        ws.onmessage = (e: any) => {
          const s = parseWsMessage(String(e?.data), printerId);
          if (s && !cancelled) setStatus(s);
        };
        ws.onclose = () => {
          if (cancelled) return;
          setConnected(false);
          startPolling();
        };
        ws.onerror = () => ws.close();
      } catch {
        if (!cancelled) startPolling();
      }
    }

    connect();
    return () => {
      cancelled = true;
      if (pollTimer) clearInterval(pollTimer);
      wsRef.current?.close();
    };
  }, [client, printerId]);

  return { status, connected };
}
