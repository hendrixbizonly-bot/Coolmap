import { recentDecisions } from '../../../lib/decision-log';
export const dynamic = 'force-dynamic';
export function GET() {
  return Response.json({ decisions: recentDecisions() }, { headers: { 'Cache-Control': 'no-store' } });
}
