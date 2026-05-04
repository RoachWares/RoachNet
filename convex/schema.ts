import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const releaseChannel = v.union(
  v.literal("desktop"),
  v.literal("ios"),
  v.literal("homebrew"),
  v.literal("sidestore"),
  v.literal("site"),
  v.literal("api")
);

const buildKind = v.union(
  v.literal("unsigned"),
  v.literal("ad-hoc-signed"),
  v.literal("developer-id-signed"),
  v.literal("notarized")
);

export default defineSchema({
  releaseEvents: defineTable({
    project: v.string(),
    version: v.string(),
    channel: releaseChannel,
    buildKind,
    releaseUrl: v.optional(v.string()),
    assetName: v.optional(v.string()),
    checksumSha256: v.optional(v.string()),
    notes: v.optional(v.string()),
    publishedAt: v.number(),
    createdBy: v.optional(v.string()),
  })
    .index("by_project_version", ["project", "version"])
    .index("by_channel", ["channel"])
    .index("by_published_at", ["publishedAt"]),

  companyUpdates: defineTable({
    title: v.string(),
    body: v.string(),
    surface: v.union(
      v.literal("public-site"),
      v.literal("github"),
      v.literal("release"),
      v.literal("internal")
    ),
    publishedAt: v.number(),
  }).index("by_published_at", ["publishedAt"]),
});
