import { decideReroute, rerouteSchema } from '../../../lib/reroute';
export async function POST(request: Request) {
  let body: unknown;
  try { body = await request.json(); } catch { return Response.json({ error: 'Invalid JSON' }, { status: 400 }); }
  const parsed = rerouteSchema.safeParse(body);
  if (!parsed.success) return Response.json({ error: 'Invalid reroute request' }, { status: 400 });
  return Response.json(await decideReroute(parsed.data));
}
