import { useEffect, useRef, useState } from 'react';
import type { BambuddyClient } from '../api/bambuddyClient';
import type { PrinterStatus } from '../api/types';

/** Pure: extract (printerId, status) from a raw WS frame, else null. The single Bambuddy socket
 *  carries frames for EVERY registered printer. */
export function parseWsFrame(raw: string): { printerId: number; status: PrinterStatus } | null {
  try {
    const m = JSON.parse(raw);
    if (m?.type === 'printer_status' && typeof m.printer_id === 'number' && m.data) {
      return { printerId: m.printer_id, status: m.data as PrinterStatus };
    }
    return null;
  } catch {
    return null;
  }
}

/** Pure: a specific printer's status from a raw WS frame, else null. */
export function parseWsMessage(raw: string, printerId: number): PrinterStatus | null {
  const f = parseWsFrame(raw);
  return f && f.printerId === printerId ? f.status : null;
}

const POLL_MS = 3000;
const RECONNECT_MS = 12_000;

/**
 * Live printer status via WebSocket, with a REST-poll fallback for the selected printer while the
 * socket is down (and periodic WS reconnect attempts). Returns the selected printer's status plus
 * the latest known status of every printer seen on the socket — the fleet switcher and the Live
 * Activity's "follow the printing machine" logic read the map.
 */
export function usePrinterStatus(client: BambuddyClient, printerId: number) {
  const [statuses, setStatuses] = useState<Record<number, PrinterStatus>>({});
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);

  // The socket is per-client (NOT per-printer): switching printers must not drop it.
  useEffect(() => {
    let cancelled = false;
    let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

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
          const f = parseWsFrame(String(e?.data));
          if (f && !cancelled) setStatuses((prev) => ({ ...prev, [f.printerId]: f.status }));
        };
        ws.onclose = () => {
          if (cancelled) return;
          setConnected(false);
          reconnectTimer = setTimeout(connect, RECONNECT_MS);
        };
        ws.onerror = () => ws.close();
      } catch {
        if (!cancelled) reconnectTimer = setTimeout(connect, RECONNECT_MS);
      }
    }

    connect();
    return () => {
      cancelled = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      wsRef.current?.close();
    };
  }, [client]);

  // REST fallback: poll the SELECTED printer while the socket is down (plus one immediate fetch
  // so the first paint doesn't wait for a socket frame).
  useEffect(() => {
    if (connected) return;
    let cancelled = false;
    const poll = async () => {
      try {
        const s = await client.getStatus(printerId);
        if (!cancelled) setStatuses((prev) => ({ ...prev, [printerId]: s }));
      } catch {
        /* keep polling */
      }
    };
    void poll();
    const id = setInterval(poll, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [client, printerId, connected]);

  return { status: statuses[printerId] ?? null, statuses, connected };
}
