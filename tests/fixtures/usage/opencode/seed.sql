CREATE TABLE `message` (
  `id` text PRIMARY KEY,
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL
);
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
  ('m1', 'oc-sess-1', 1789900000000, 1789900000000,
   '{"role":"assistant","modelID":"gpt-6-astra","providerID":"opencode","tokens":{"input":4000,"output":200,"cache":{"read":0,"write":0}}}'),
  ('m2', 'oc-sess-1', 1789800000000, 1789800000000,
   '{"role":"user","modelID":"gpt-6-astra","providerID":"opencode","tokens":{"input":0,"output":0,"cache":{"read":0,"write":0}}}'),
  ('m3', 'oc-sess-old', 1600000000000, 1600000000000,
   '{"role":"assistant","modelID":"gpt-6-astra","providerID":"opencode","tokens":{"input":9999,"output":999,"cache":{"read":0,"write":0}}}');
