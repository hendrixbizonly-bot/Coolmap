'use client';
import { useEffect, useState } from 'react';
import type { Decision } from '../../lib/decision-log';
import styles from './page.module.css';

const time = (value: string) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Dubai', hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date(value));
const decider = (d: Decision) => ({ jev: 'Jev', hard_trigger: 'Safety rule', rule: 'Backup rule', none: 'No reroute' }[d.response.reason]);
const heatSaved = ({ request: r }: Decision) => !r.alternative ? 'no alternative' : r.current.remainingHeat <= 0 ? '—' : `${Math.round((1 - r.alternative.heat / r.current.remainingHeat) * 100)}%`;
const extraTime = ({ request: r }: Decision) => {
  if (!r.alternative) return '—';
  const seconds = Math.round(r.alternative.totalSeconds - r.current.remainingSeconds);
  const absolute = Math.abs(seconds);
  return `${seconds < 0 ? '−' : '+'}${Math.floor(absolute / 60)} min ${String(absolute % 60).padStart(2, '0')} s`;
};
const hazard = ({ request: r }: Decision) => {
  const h = r.hazardsAhead[0];
  return h ? `${h.note || h.category} · ${Math.round(h.metersAhead)} m` : 'none';
};

export default function Demo() {
  const [decisions, setDecisions] = useState<Decision[]>([]);
  const [offline, setOffline] = useState(false);
  useEffect(() => {
    let disposed = false;
    let inFlight = false;
    const controller = new AbortController();
    const load = async () => {
      if (inFlight) return;
      inFlight = true;
      try {
        const response = await fetch('/api/decisions', { cache: 'no-store', signal: controller.signal });
        if (!response.ok) throw new Error(String(response.status));
        const body = await response.json();
        if (!disposed) {
          setDecisions(body.decisions);
          setOffline(false);
        }
      } catch {
        if (!disposed) setOffline(true);
      } finally {
        inFlight = false;
      }
    };
    load();
    const timer = setInterval(load, 1000);
    return () => {
      disposed = true;
      clearInterval(timer);
      controller.abort();
    };
  }, []);
  const latest = decisions[0];
  const worth = latest?.response.debug.questions.find(q => q.id === 'rerouteWorthIt');
  const confidence = worth ? Math.round(Math.max(0, Math.min(1, worth.probability)) * 100) : undefined;
  return (
    <main className={styles.panel}>
      <header className={styles.header}>
        <span>COOLMAP / LIVE</span>
        <span>{offline ? 'Reconnecting…' : 'Checking every second'}</span>
      </header>
      <h1>Jev live decisions</h1>
      {!latest ? (
        <section className={styles.hero}>
          <h2>Waiting for the first reroute check…</h2>
        </section>
      ) : (
        <>
          <section className={styles.hero}>
            <div className={styles.meta}>
              <span className={styles.badge}>{decider(latest)}</span>
              <time>{time(latest.receivedAt)} UAE</time>
            </div>
            {latest.response.debug.jev === 'failed' && <p className={styles.warning}>Jev unavailable</p>}
            {worth ? (
              <>
                <h2>Worth rerouting? {worth.answer ? 'Yes' : 'No'} · {confidence}%</h2>
                <div role="progressbar" aria-label="Reroute confidence" aria-valuemin={0} aria-valuemax={100} aria-valuenow={confidence} className={styles.track}>
                  <span style={{ width: `${confidence}%` }} />
                </div>
                <p className={styles.outcome}>{latest.response.prompt ? 'Cooler way suggested' : 'Stayed quiet'}</p>
              </>
            ) : (
              <h2>{latest.response.prompt ? 'Cooler way suggested' : 'Stayed quiet'}</h2>
            )}
            <span className={styles.urgency}>Urgency {latest.response.urgency}/3</span>
            <dl className={styles.inputs}>
              <div><dt>Heat saved</dt><dd>{heatSaved(latest)}</dd></div>
              <div><dt>Extra time</dt><dd>{extraTime(latest)}</dd></div>
              <div><dt>Temperature</dt><dd>{latest.response.debug.temperatureC === undefined ? '—' : `${latest.response.debug.temperatureC}°C`}</dd></div>
              <div><dt>To sunset</dt><dd>{Math.round(latest.request.minutesToSunset)} min</dd></div>
              <div className={styles.hazard}><dt>Hazard ahead</dt><dd>{hazard(latest)}</dd></div>
            </dl>
          </section>
          <section className={styles.timeline}>
            <h3>Earlier checks <span>{Math.max(0, decisions.length - 1)}</span></h3>
            <ol>
              {decisions.slice(1, 20).map(d => (
                <li key={d.id} className={styles.row}>
                  <div className={styles.rowTop}>
                    <time>{time(d.receivedAt)}</time>
                    <strong>{d.response.prompt ? 'Suggested' : 'Stayed quiet'}</strong>
                    <span>{decider(d)}</span>
                  </div>
                  <div className={styles.rowDetail}>
                    <span>{heatSaved(d)} heat saved</span>
                    <span>{hazard(d)}</span>
                  </div>
                </li>
              ))}
            </ol>
          </section>
        </>
      )}
    </main>
  );
}
