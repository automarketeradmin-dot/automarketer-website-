// =============================================================================
// AUTOMARKETER — submit-lead Edge Function
// =============================================================================
// Deploy with the Supabase CLI:
//   supabase functions deploy submit-lead --no-verify-jwt
//
// Required environment variables (set with `supabase secrets set ...` —
// NEVER put these in frontend code or commit them to git):
//   SUPABASE_URL                      — auto-provided in the Edge Function runtime
//   SUPABASE_SERVICE_ROLE_KEY         — service-role key (server-side only)
//   WHATSAPP_PHONE_NUMBER_ID          — from Meta's WhatsApp Business app
//   WHATSAPP_BUSINESS_ACCOUNT_ID      — from Meta's WhatsApp Business app
//   WHATSAPP_ACCESS_TOKEN             — permanent system-user access token
//   WHATSAPP_API_VERSION              — e.g. "v20.0"
//   WHATSAPP_DESTINATION_NUMBER       — AutoMarketer's own number, e.g. "27754910677"
//
// This function is intentionally defensive: if the WhatsApp send fails, the
// lead is still saved and marked whatsapp_notification_status = 'failed'
// with the error recorded — the lead is never lost (brief Section 21).
// =============================================================================

import { serve } from "https://deno.land/std@0.203.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WA_PHONE_NUMBER_ID = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
const WA_ACCESS_TOKEN = Deno.env.get("WHATSAPP_ACCESS_TOKEN") ?? "";
const WA_API_VERSION = Deno.env.get("WHATSAPP_API_VERSION") ?? "v20.0";
const WA_DESTINATION = Deno.env.get("WHATSAPP_DESTINATION_NUMBER") ?? "";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const MAX_PHOTOS = 8;
const MAX_PHOTO_BYTES = 6 * 1024 * 1024; // 6MB per photo
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

// Simple in-memory rate limit (per Edge Function instance — for real
// production-grade rate limiting, front this with Supabase's built-in
// rate limiting or a WAF/CDN rule instead).
const recentSubmissions = new Map<string, number[]>();
function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const windowMs = 60_000;
  const maxPerWindow = 5;
  const hits = (recentSubmissions.get(ip) ?? []).filter(t => now - t < windowMs);
  hits.push(now);
  recentSubmissions.set(ip, hits);
  return hits.length > maxPerWindow;
}

type LeadPayload = {
  id: string;
  lead_type: "buy" | "sell" | "spotter" | "insurance" | "contract" | "other";
  name?: string; phone?: string; email?: string; location?: string;
  client_name?: string; client_phone?: string;
  vehicle_make?: string; vehicle_model?: string; vehicle_year?: number;
  mileage?: number; transmission?: string; vehicle_condition?: string;
  budget?: number; asking_price?: number; description?: string;
  agreement_accepted: boolean; agreement_version?: string;
  consent_status: "given" | "not_given";
  source?: string;
  photos?: { name: string; base64: string; mimeType: string }[]; // dataURL split by the frontend
  whatsapp_message: string; // pre-built natural-language message from the frontend
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" }
  });
}

function validatePayload(p: LeadPayload): string | null {
  if (!p.id || !p.lead_type) return "Missing id or lead_type";
  if (!p.consent_status || p.consent_status !== "given") return "Consent not given";
  if (["buy", "sell", "spotter"].includes(p.lead_type) && !p.agreement_accepted) {
    return "Required agreement not accepted";
  }
  if (p.phone && !/^\+?\d{9,15}$/.test(p.phone.replace(/\s+/g, ""))) return "Invalid phone number";
  if (p.photos) {
    if (p.photos.length > MAX_PHOTOS) return `Too many photos (max ${MAX_PHOTOS})`;
    for (const ph of p.photos) {
      if (!ALLOWED_TYPES.has(ph.mimeType)) return `Unsupported file type: ${ph.mimeType}`;
      const approxBytes = (ph.base64.length * 3) / 4;
      if (approxBytes > MAX_PHOTO_BYTES) return `Photo too large: ${ph.name}`;
    }
  }
  return null;
}

async function uploadPhotos(leadId: string, photos: LeadPayload["photos"]): Promise<string[]> {
  if (!photos || !photos.length) return [];
  const paths: string[] = [];
  for (const [i, ph] of photos.entries()) {
    const path = `${leadId}/${i}-${ph.name}`;
    const bytes = Uint8Array.from(atob(ph.base64), c => c.charCodeAt(0));
    const { error } = await supabase.storage.from("lead-uploads").upload(path, bytes, {
      contentType: ph.mimeType, upsert: true
    });
    if (!error) paths.push(path);
  }
  return paths;
}

// WhatsApp Cloud API: upload one media item, return its media_id
async function uploadWhatsAppMedia(bytes: Uint8Array, mimeType: string): Promise<string | null> {
  const form = new FormData();
  form.append("messaging_product", "whatsapp");
  form.append("file", new Blob([bytes], { type: mimeType }));
  const res = await fetch(
    `https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_NUMBER_ID}/media`,
    { method: "POST", headers: { Authorization: `Bearer ${WA_ACCESS_TOKEN}` }, body: form }
  );
  if (!res.ok) return null;
  const data = await res.json();
  return data.id ?? null;
}

async function sendWhatsAppText(message: string): Promise<{ ok: boolean; messageId?: string; error?: string }> {
  try {
    const res = await fetch(
      `https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_NUMBER_ID}/messages`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${WA_ACCESS_TOKEN}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          to: WA_DESTINATION,
          type: "text",
          text: { body: message }
        })
      }
    );
    const data = await res.json();
    if (!res.ok) return { ok: false, error: JSON.stringify(data) };
    return { ok: true, messageId: data.messages?.[0]?.id };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

async function sendWhatsAppPhotos(photos: LeadPayload["photos"]) {
  if (!photos) return;
  for (const ph of photos) {
    try {
      const bytes = Uint8Array.from(atob(ph.base64), c => c.charCodeAt(0));
      const mediaId = await uploadWhatsAppMedia(bytes, ph.mimeType);
      if (!mediaId) continue;
      await fetch(`https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_NUMBER_ID}/messages`, {
        method: "POST",
        headers: { Authorization: `Bearer ${WA_ACCESS_TOKEN}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          messaging_product: "whatsapp", to: WA_DESTINATION, type: "image", image: { id: mediaId }
        })
      });
    } catch (_e) {
      // A single failed photo should not fail the whole submission — the
      // lead and its other photos (in Storage) are already safe.
    }
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return jsonResponse({}, 204);
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const ip = req.headers.get("x-forwarded-for") ?? "unknown";
  if (isRateLimited(ip)) return jsonResponse({ error: "Too many requests, please try again shortly." }, 429);

  let payload: LeadPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const validationError = validatePayload(payload);
  if (validationError) return jsonResponse({ error: validationError }, 400);

  // 1. Upload photos to Storage first (so the lead row can reference paths)
  let uploadedPaths: string[] = [];
  try {
    uploadedPaths = await uploadPhotos(payload.id, payload.photos);
  } catch (e) {
    console.error("Photo upload failed", e);
  }

  // 2. Insert the lead (idempotent on id — re-submits update rather than duplicate)
  const { error: dbError } = await supabase.from("leads").upsert({
    id: payload.id,
    lead_type: payload.lead_type,
    name: payload.name ?? null,
    phone: payload.phone ?? null,
    email: payload.email ?? null,
    location: payload.location ?? null,
    client_name: payload.client_name ?? null,
    client_phone: payload.client_phone ?? null,
    vehicle_make: payload.vehicle_make ?? null,
    vehicle_model: payload.vehicle_model ?? null,
    vehicle_year: payload.vehicle_year ?? null,
    mileage: payload.mileage ?? null,
    transmission: payload.transmission ?? null,
    vehicle_condition: payload.vehicle_condition ?? null,
    budget: payload.budget ?? null,
    asking_price: payload.asking_price ?? null,
    description: payload.description ?? null,
    uploaded_files: uploadedPaths,
    agreement_accepted: payload.agreement_accepted,
    agreement_version: payload.agreement_version ?? null,
    agreement_accepted_at: payload.agreement_accepted ? new Date().toISOString() : null,
    consent_status: payload.consent_status,
    source: payload.source ?? null,
    whatsapp_notification_status: "pending"
  });

  if (dbError) {
    console.error("DB insert failed", dbError);
    return jsonResponse({ error: "Could not save lead", details: dbError.message }, 500);
  }

  // 3. Send the WhatsApp notification. The lead is already saved at this
  //    point, so a WhatsApp failure never loses the lead (brief Section 21).
  let waStatus: "sent" | "failed" = "failed";
  let waMessageId: string | null = null;
  let waError: string | null = null;

  if (!WA_PHONE_NUMBER_ID || !WA_ACCESS_TOKEN || !WA_DESTINATION) {
    waError = "WhatsApp Business Cloud API is not configured (missing environment variables).";
  } else {
    const result = await sendWhatsAppText(payload.whatsapp_message);
    if (result.ok) {
      waStatus = "sent";
      waMessageId = result.messageId ?? null;
      if (payload.lead_type === "sell") await sendWhatsAppPhotos(payload.photos);
    } else {
      waError = result.error ?? "Unknown WhatsApp API error";
    }
  }

  await supabase.from("leads").update({
    whatsapp_notification_status: waStatus,
    whatsapp_message_id: waMessageId,
    notification_error: waError
  }).eq("id", payload.id);

  return jsonResponse({
    ok: true,
    leadId: payload.id,
    whatsapp_notification_status: waStatus,
    notification_error: waError
  });
});
