// Edge Function "gui-push": gửi thông báo đẩy (Web Push) cho chat nội bộ.
// Chỉ database gọi hàm này (trigger trong chat-4.sql), kèm header x-bi-mat = PUSH_BI_MAT.
// Secrets cần đặt trong Supabase → Edge Functions → Secrets:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:...), PUSH_BI_MAT
// SUPABASE_URL và SUPABASE_SERVICE_ROLE_KEY Supabase tự cấp sẵn.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") || "mailto:admin@vanban.name.vn",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

type ThongBao = { title: string; body: string; url: string; tag: string; goi?: boolean; ht?: number; icon?: string };

// Ảnh đại diện người gửi/người gọi → hiện trên thông báo (không có thì dùng logo app)
async function anhDaiDien(id: number) {
  const { data } = await db.from("ht_nguoi").select("anh").eq("employee_id", id).maybeSingle();
  if (!data?.anh) return undefined;
  return Deno.env.get("SUPABASE_URL") + "/storage/v1/object/public/ht-anh/" + data.anh.split("/").map(encodeURIComponent).join("/");
}

function moTa(m: { loai: string; noi_dung: string | null }) {
  if (m.loai === "anh") return "📷 Hình ảnh";
  return (m.noi_dung || "").slice(0, 140);
}

async function guiCho(ids: number[], tb: ThongBao) {
  if (!ids.length) return 0;
  const { data: subs } = await db.from("ht_dang_ky_push").select("endpoint,p256dh,auth").in("employee_id", ids);
  let ok = 0;
  await Promise.all((subs || []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(tb),
        { TTL: tb.goi ? 60 : 86400, urgency: "high" },
      );
      ok++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from("ht_dang_ky_push").delete().eq("endpoint", s.endpoint); // thiết bị đã huỷ
    }
  }));
  return ok;
}

async function tinMoi(id: number) {
  const { data: m } = await db.from("ht_tin_nhan").select("id,hoi_thoai_id,nguoi_gui,loai,noi_dung,nhac").eq("id", id).single();
  if (!m) return 0;
  const [{ data: h }, { data: gui }, { data: tvs }] = await Promise.all([
    db.from("ht_hoi_thoai").select("id,loai,ten").eq("id", m.hoi_thoai_id).single(),
    db.from("employees").select("ten").eq("id", m.nguoi_gui).single(),
    db.from("ht_thanh_vien").select("employee_id,tat_tb").eq("hoi_thoai_id", m.hoi_thoai_id),
  ]);
  const ten = gui?.ten || "Tin nhắn";
  const icon = await anhDaiDien(m.nguoi_gui);
  const nhac: number[] = m.nhac || [];
  // người tắt thông báo vẫn nhận khi bị @nhắc tên (giống Zalo)
  const nhan = (tvs || []).filter((t) => t.employee_id !== m.nguoi_gui && (!t.tat_tb || nhac.includes(t.employee_id)));
  const url = "./chat.html#ht=" + m.hoi_thoai_id;
  if (h?.loai === "nhom") {
    const bth = nhan.filter((t) => !nhac.includes(t.employee_id)).map((t) => t.employee_id);
    const bn = nhan.filter((t) => nhac.includes(t.employee_id)).map((t) => t.employee_id);
    const a = await guiCho(bth, { title: h.ten || "Nhóm", body: ten + ": " + moTa(m), url, tag: "ht-" + m.hoi_thoai_id, ht: m.hoi_thoai_id, icon });
    const b = await guiCho(bn, { title: h.ten || "Nhóm", body: ten + " đã nhắc đến bạn: " + moTa(m), url, tag: "ht-" + m.hoi_thoai_id, ht: m.hoi_thoai_id, icon });
    return a + b;
  }
  return guiCho(nhan.map((t) => t.employee_id), { title: ten, body: moTa(m), url, tag: "ht-" + m.hoi_thoai_id, ht: m.hoi_thoai_id, icon });
}

async function cuocGoi(id: number) {
  const { data: g } = await db.from("ht_cuoc_goi").select("id,hoi_thoai_id,nguoi_goi,nguoi_nghe,loai,trang_thai").eq("id", id).single();
  if (!g || g.trang_thai !== "do_chuong") return 0; // người gọi đã huỷ trước khi kịp gửi → không báo cuộc gọi cũ
  const { data: gui } = await db.from("employees").select("ten").eq("id", g.nguoi_goi).single();
  return guiCho([g.nguoi_nghe], {
    icon: await anhDaiDien(g.nguoi_goi),
    title: "📞 Cuộc gọi " + (g.loai === "video" ? "video" : "thoại") + " đến",
    body: (gui?.ten || "Ai đó") + " đang gọi cho bạn... Bấm để nghe",
    url: "./chat.html#ht=" + g.hoi_thoai_id + "&goi=" + g.id,
    tag: "goi-" + g.id, goi: true, ht: g.hoi_thoai_id,
  });
}

Deno.serve(async (req) => {
  if (req.headers.get("x-bi-mat") !== Deno.env.get("PUSH_BI_MAT")) return new Response("forbidden", { status: 403 });
  try {
    const b = await req.json();
    const n = b.loai === "goi" ? await cuocGoi(Number(b.goi)) : await tinMoi(Number(b.tin));
    return new Response(JSON.stringify({ da_gui: n }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ loi: String(e) }), { status: 500 });
  }
});
