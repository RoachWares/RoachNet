import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

const companyProfile = {
  name: "RoachWares LLC",
  jurisdiction: "Indiana",
  home: "https://roachwares.roachnet.org/",
  github: "https://github.com/RoachWares",
  product: "RoachNet",
  posture:
    "Offline-first software from the company behind RoachNet. Online services are support rails, not the floor.",
};

export const company = query({
  args: {},
  handler: () => companyProfile,
});

export const health = query({
  args: {},
  handler: () => ({
    ok: true,
    service: "roachwares-convex",
    company: companyProfile.name,
    checkedAt: Date.now(),
  }),
});

export const latestRelease = query({
  args: {
    project: v.string(),
    channel: v.optional(
      v.union(
        v.literal("desktop"),
        v.literal("ios"),
        v.literal("homebrew"),
        v.literal("sidestore"),
        v.literal("site"),
        v.literal("api")
      )
    ),
  },
  handler: async (ctx, args) => {
    const events = await ctx.db
      .query("releaseEvents")
      .withIndex("by_published_at")
      .order("desc")
      .take(50);

    return (
      events.find((event) => {
        if (event.project !== args.project) return false;
        if (args.channel && event.channel !== args.channel) return false;
        return true;
      }) ?? null
    );
  },
});

export const listReleaseEvents = query({
  args: {
    project: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(args.limit ?? 25, 1), 100);
    const events = await ctx.db
      .query("releaseEvents")
      .withIndex("by_published_at")
      .order("desc")
      .take(limit * 2);

    return events
      .filter((event) => !args.project || event.project === args.project)
      .slice(0, limit);
  },
});

export const recordRelease = mutation({
  args: {
    project: v.string(),
    version: v.string(),
    channel: v.union(
      v.literal("desktop"),
      v.literal("ios"),
      v.literal("homebrew"),
      v.literal("sidestore"),
      v.literal("site"),
      v.literal("api")
    ),
    buildKind: v.union(
      v.literal("unsigned"),
      v.literal("ad-hoc-signed"),
      v.literal("developer-id-signed"),
      v.literal("notarized")
    ),
    releaseUrl: v.optional(v.string()),
    assetName: v.optional(v.string()),
    checksumSha256: v.optional(v.string()),
    notes: v.optional(v.string()),
    publishedAt: v.optional(v.number()),
    createdBy: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    return await ctx.db.insert("releaseEvents", {
      ...args,
      publishedAt: args.publishedAt ?? Date.now(),
    });
  },
});

export const latestCompanyUpdates = query({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(args.limit ?? 10, 1), 50);
    return await ctx.db
      .query("companyUpdates")
      .withIndex("by_published_at")
      .order("desc")
      .take(limit);
  },
});
