/** All coordinates are WGS84 [longitude, latitude]; timestamps are ISO8601 UTC. */
export type Position = [number, number];
export type Risk = 'high' | 'medium' | 'low' | 'unknown';
export interface TrackPoint { coordinates: Position; time: string }
export interface CandidateVessel {
  mmsi: string; name: string; type: string; flag: string | null;
  position: Position | null; positionTime: string | null;
  speedKnots: number | null; course: number | null; distanceNm: number | null;
  probability: number | null; // 0..100, provided by analysis service; never inferred from proximity alone
  passageTime: string | null;
  closest: { coordinates: Position; time: string; basis: string } | null;
  anomalies: { signalGap: boolean | null; loitering: boolean | null; slowdown: boolean | null; aisOff: boolean | null };
  track: TrackPoint[]; trackWindow?: { start: string; end: string };
  trackTruncated?: boolean; trackError?: string;
}
export interface OilAlertEvent {
  id: string; detectedAt: string; releaseTime: string | null; risk: Risk;
  center: Position; geometry: { type: 'Polygon' | 'MultiPolygon' | 'Point'; coordinates: unknown };
  areaKm2: number | null; lengthKm: number | null; widthKm: number | null;
  morphology: string | null; source: string; confidence: number | null;
  imageUrl: string | null; driftDirection: string | null; driftSpeedKnots: number | null;
  forecasts: { hours: 1 | 3 | 6; geometry: OilAlertEvent['geometry']; areaKm2: number | null }[];
  candidates: CandidateVessel[]; provenance: 'development' | 'api';
  candidateStatus: 'ready' | 'pending' | 'error'; candidateError?: string;
}
export interface AlertRecord {
  event: OilAlertEvent; receivedAt: string; status: 'unhandled' | 'acknowledged';
  acknowledgedAt: string | null; acknowledgedBy: string | null;
  acknowledgementScope: 'local' | 'server';
}
export interface AlertAdapter {
  enrich(event: OilAlertEvent): Promise<OilAlertEvent>;
  loadTrack(event: OilAlertEvent, vessel: CandidateVessel): Promise<CandidateVessel>;
  acknowledge?(record: AlertRecord, user: { id: string; name?: string } | null): Promise<{ acknowledgedAt: string; acknowledgedBy?: string }>;
}
