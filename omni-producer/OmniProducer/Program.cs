// Omni Producer - native CLI port of Invoke-OmniProducer.ps1 (flag-compatible).
// Spec: omni-producer-CLI-TINS.md. API shapes are live-API verified; see the
// TINS "Live-API amendments" section for where they supersede the docs.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OmniProducer
{
    internal sealed class Config
    {
        public string ApiKey = "";
        public string Model = "gemini-omni-flash-preview";
        public string EndpointBase = "https://generativelanguage.googleapis.com/v1beta";
        public string UploadEndpointBase = "https://generativelanguage.googleapis.com/upload/v1beta/files";
        public string DefaultAspectRatio = "16:9";
        public string DefaultDelivery = "uri";
        public bool Store = true;
        public int TimeoutSeconds = 600;
        public int PollIntervalSeconds = 5;
        public int PollTimeoutSeconds = 600;
        public int UploadPollIntervalSeconds = 3;
        public int UploadPollTimeoutSeconds = 300;
        public int MaxRetries = 2;
        public int DelayBetweenJobsSeconds = 2;
        public bool SaveResponseJson = true;
        public bool SaveJobSidecar = true;
        public int SlugMaxLength = 80;
        public string FfmpegPath = "ffmpeg";
        public string FfprobePath = "ffprobe";
        public int GenerationSeconds = 8;
    }

    internal sealed class Job
    {
        public int Index;
        public string Title = "";
        public string Prompt = "";
        public string TaskExplicit = "";
        public string Task = "";
        public string Aspect = "";
        public string Delivery = "";
        public string Image = "";
        public readonly List<string> Refs = new List<string>();
        public string Source = "";
        public string EditFrom = "";
        public readonly List<string> Errors = new List<string>();

        // Sequence mode (Stage 3): directives as parsed from the catalogue/manifest.
        public string Split = "";
        public int SegmentSeconds = 0;   // 0 = unset -> resolves to cfg.GenerationSeconds
        public bool? Walk = null;        // null = default (on when Split is set)
        public bool? Vision = null;      // null = default (on when Walk resolves on)

        // Sequence mode: set by SequencePlanner on the expanded per-segment jobs.
        public bool IsSequenceSegment = false;
        public int SeqParentIndex = 0;
        public int SeqIndex = 0;
        public int SeqCount = 0;
        public string SeqSegmentPath = "";
        public string SeqFramePath = "";
        public string SeqVisionText = "";
    }

    internal sealed class Totals
    {
        public int Planned, Generated, Skipped, Failed;
    }

    internal static class Program
    {
        private const string NetworkErrorMsg = "Couldn't reach Gemini - check your connection and retry.";
        private static readonly string[] ValidTasks = { "text_to_video", "image_to_video", "reference_to_video", "edit" };
        private static readonly string[] VideoExts = { ".mp4", ".mov", ".webm", ".m4v" };
        private const int MaxReferences = 6;
        private const long MaxUploadBytes = 2L * 1024 * 1024 * 1024;

        private static readonly Dictionary<string, string> ImageMimes =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                [".png"] = "image/png",
                [".jpg"] = "image/jpeg",
                [".jpeg"] = "image/jpeg",
                [".webp"] = "image/webp",
            };

        private static readonly Regex DirectiveRe = new Regex(
            @"^\s*(?:\*\*|__)?(task|aspect|delivery|image|ref|source|edit-from|split|segment|walk|vision)(?:\s*:\s*(?:\*\*|__)?|\s*(?:\*\*|__)\s*:)\s*(.+?)\s*$",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static readonly HttpClient Http = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan   // per-request CTS instead
        };

        // -------------------------------------------------------------------
        // Console helpers
        // -------------------------------------------------------------------

        private static void W(string text, ConsoleColor? color = null)
        {
            if (color.HasValue) Console.ForegroundColor = color.Value;
            Console.WriteLine(text);
            if (color.HasValue) Console.ResetColor();
        }

        // -------------------------------------------------------------------
        // Config
        // -------------------------------------------------------------------

        private static Config LoadConfig(string configPath)
        {
            var cfg = new Config();
            if (string.IsNullOrEmpty(configPath))
                configPath = Path.Combine(AppContext.BaseDirectory, "config.cfg");

            if (!File.Exists(configPath))
            {
                W($"WARNING: Config not found at '{configPath}'. Using built-in defaults.", ConsoleColor.Yellow);
                return cfg;
            }

            var raw = File.ReadAllText(configPath, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(raw)) return cfg;
            var node = JsonNode.Parse(raw) as JsonObject;
            if (node == null) return cfg;

            string S(string key, string cur) => node[key] != null ? node[key].GetValue<string>() : cur;
            int I(string key, int cur) => node[key] != null ? node[key].GetValue<int>() : cur;
            bool B(string key, bool cur) => node[key] != null ? node[key].GetValue<bool>() : cur;

            cfg.ApiKey = S("apiKey", cfg.ApiKey);
            cfg.Model = S("model", cfg.Model);
            cfg.EndpointBase = S("endpointBase", cfg.EndpointBase);
            cfg.UploadEndpointBase = S("uploadEndpointBase", cfg.UploadEndpointBase);
            cfg.DefaultAspectRatio = S("defaultAspectRatio", cfg.DefaultAspectRatio);
            cfg.DefaultDelivery = S("defaultDelivery", cfg.DefaultDelivery);
            cfg.Store = B("store", cfg.Store);
            cfg.TimeoutSeconds = I("timeoutSeconds", cfg.TimeoutSeconds);
            cfg.PollIntervalSeconds = I("pollIntervalSeconds", cfg.PollIntervalSeconds);
            cfg.PollTimeoutSeconds = I("pollTimeoutSeconds", cfg.PollTimeoutSeconds);
            cfg.UploadPollIntervalSeconds = I("uploadPollIntervalSeconds", cfg.UploadPollIntervalSeconds);
            cfg.UploadPollTimeoutSeconds = I("uploadPollTimeoutSeconds", cfg.UploadPollTimeoutSeconds);
            cfg.MaxRetries = I("maxRetries", cfg.MaxRetries);
            cfg.DelayBetweenJobsSeconds = I("delayBetweenJobsSeconds", cfg.DelayBetweenJobsSeconds);
            cfg.SaveResponseJson = B("saveResponseJson", cfg.SaveResponseJson);
            cfg.SaveJobSidecar = B("saveJobSidecar", cfg.SaveJobSidecar);
            cfg.SlugMaxLength = I("slugMaxLength", cfg.SlugMaxLength);
            cfg.FfmpegPath = S("ffmpegPath", cfg.FfmpegPath);
            cfg.FfprobePath = S("ffprobePath", cfg.FfprobePath);
            cfg.GenerationSeconds = I("generationSeconds", cfg.GenerationSeconds);
            return cfg;
        }

        // -------------------------------------------------------------------
        // String helpers (behavior identical to the PowerShell implementation)
        // -------------------------------------------------------------------

        private static string Slugify(string text, int maxLength)
        {
            if (string.IsNullOrWhiteSpace(text)) return "untitled";

            var s = Regex.Replace(text, @"[*_`~]", "");
            s = Regex.Replace(s, @"(?<=\d),(?=\d)", "");
            s = s.Replace("ß", "ss")
                 .Replace("ø", "o").Replace("Ø", "o")
                 .Replace("æ", "ae").Replace("Æ", "ae")
                 .Replace("œ", "oe").Replace("Œ", "oe");

            var norm = s.Normalize(NormalizationForm.FormD);
            var sb = new StringBuilder();
            foreach (var ch in norm)
            {
                if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark)
                    sb.Append(ch);
            }
            s = sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
            s = Regex.Replace(s, "[^a-z0-9]+", "-").Trim('-');

            if (string.IsNullOrWhiteSpace(s)) return "untitled";
            if (s.Length > maxLength) s = s.Substring(0, maxLength).Trim('-');
            return s;
        }

        private static string OutputFolderName(string fileBaseName)
        {
            var parts = Regex.Split(fileBaseName, @"[-_\s]+").Where(p => p != "").Take(4);
            return string.Join("-", parts).ToLowerInvariant();
        }

        private static string ResolveJobPath(string baseDir, string value)
        {
            var v = value.Trim().Trim('"').Trim('\'');
            return Path.GetFullPath(Path.IsPathRooted(v) ? v : Path.Combine(baseDir, v));
        }

        private static string GetVideoMime(string filePath)
        {
            switch (Path.GetExtension(filePath).ToLowerInvariant())
            {
                case ".mov": return "video/quicktime";
                case ".webm": return "video/webm";
                case ".m4v": return "video/x-m4v";
                default: return "video/mp4";
            }
        }

        // -------------------------------------------------------------------
        // Task resolution + validation (messages identical to the PS1)
        // -------------------------------------------------------------------

        private static void ResolveJobTask(Job job)
        {
            bool hasImage = job.Image != "";
            bool hasRefs = job.Refs.Count > 0;
            bool hasSource = job.Source != "";
            bool hasEditFrom = job.EditFrom != "";
            bool hasSplit = job.Split != "";

            if (!hasSplit && job.SegmentSeconds != 0) job.Errors.Add("Segment requires Split");
            if (!hasSplit && job.Walk.HasValue) job.Errors.Add("Walk requires Split");
            if (!hasSplit && job.Vision.HasValue) job.Errors.Add("Vision requires Split");
            if (hasSplit && (hasImage || hasRefs || hasSource || hasEditFrom))
                job.Errors.Add("Split cannot be combined with Image/Ref/Source/Edit-from");
            if (hasSplit && job.TaskExplicit != "" && job.TaskExplicit != "edit")
                job.Errors.Add("Split jobs always use task edit per segment - remove Task or set it to edit");

            if (job.TaskExplicit != "" && !ValidTasks.Contains(job.TaskExplicit))
            {
                job.Errors.Add($"unknown task '{job.TaskExplicit}'");
                return;
            }
            if (job.Aspect != "" && job.Aspect != "16:9" && job.Aspect != "9:16")
                job.Errors.Add($"invalid aspect '{job.Aspect}' (use 16:9 or 9:16)");
            if (job.Delivery != "" && job.Delivery != "inline" && job.Delivery != "uri")
                job.Errors.Add($"invalid delivery '{job.Delivery}' (use inline or uri)");

            if (hasSource && (hasImage || hasRefs))
                job.Errors.Add("Source cannot be combined with Image/Ref");
            if (hasEditFrom && (hasImage || hasRefs || hasSource))
                job.Errors.Add("Edit-from cannot be combined with Image/Ref/Source");
            if (hasRefs && !hasImage)
                job.Errors.Add("Ref requires an Image (the first-frame image)");
            if (job.Refs.Count > MaxReferences)
                job.Errors.Add($"too many references ({job.Refs.Count}; max {MaxReferences})");

            string inferred =
                hasSplit ? "edit" :
                hasEditFrom ? "edit" :
                hasSource ? "edit" :
                (hasImage && hasRefs) ? "reference_to_video" :
                hasImage ? "image_to_video" : "text_to_video";

            if (hasSplit)
            {
                // Split jobs are replaced by per-segment edit jobs before the queue
                // runs (SequencePlanner); the parent's own task is never sent.
                job.Task = "edit";
                return;
            }

            if (job.TaskExplicit != "")
            {
                switch (job.TaskExplicit)
                {
                    case "text_to_video":
                        if (hasImage || hasRefs || hasSource || hasEditFrom)
                            job.Errors.Add("text_to_video takes no media or Edit-from");
                        break;
                    case "image_to_video":
                        if (!hasImage) job.Errors.Add("image_to_video requires an Image");
                        if (hasRefs || hasSource || hasEditFrom)
                            job.Errors.Add("image_to_video takes only an Image");
                        break;
                    case "reference_to_video":
                        if (!(hasImage && hasRefs))
                            job.Errors.Add("reference_to_video requires an Image plus at least one Ref");
                        if (hasSource || hasEditFrom)
                            job.Errors.Add("reference_to_video takes no Source/Edit-from");
                        break;
                    case "edit":
                        if (!(hasSource || hasEditFrom))
                            job.Errors.Add("edit requires a Source video or Edit-from");
                        break;
                }
                job.Task = job.TaskExplicit;
            }
            else
            {
                job.Task = inferred;
            }
        }

        private static void TestJobMedia(Job job, int jobCount)
        {
            var images = new List<string>();
            if (job.Image != "") images.Add(job.Image);
            images.AddRange(job.Refs);
            foreach (var img in images)
            {
                var ext = Path.GetExtension(img).ToLowerInvariant();
                if (!ImageMimes.ContainsKey(ext))
                    job.Errors.Add($"unsupported image type '{ext}' - use PNG, JPG, or WEBP: {img}");
                else if (!File.Exists(img))
                    job.Errors.Add($"media not found: {img}");
            }

            if (job.Source != "")
            {
                var ext = Path.GetExtension(job.Source).ToLowerInvariant();
                if (!VideoExts.Contains(ext))
                    job.Errors.Add($"Unsupported file type - use MP4, MOV, or WEBM: {job.Source}");
                else if (!File.Exists(job.Source))
                    job.Errors.Add($"media not found: {job.Source}");
                else if (new FileInfo(job.Source).Length > MaxUploadBytes)
                    job.Errors.Add("Video is larger than the 2 GB upload limit.");
            }

            if (job.Split != "")
            {
                var ext = Path.GetExtension(job.Split).ToLowerInvariant();
                if (!VideoExts.Contains(ext))
                    job.Errors.Add($"Unsupported file type - use MP4, MOV, or WEBM: {job.Split}");
                else if (!File.Exists(job.Split))
                    job.Errors.Add($"media not found: {job.Split}");
            }

            if (job.EditFrom != "")
            {
                var ef = job.EditFrom;
                var mHash = Regex.Match(ef, @"^#(\d+)$");
                if (mHash.Success)
                {
                    var n = int.Parse(mHash.Groups[1].Value);
                    if (n < 1 || n > jobCount)
                        job.Errors.Add($"Edit-from #{n} is out of range (catalogue has {jobCount} job(s))");
                    else if (n >= job.Index)
                        job.Errors.Add($"Edit-from #{n} must reference an earlier job (this is job {job.Index})");
                }
                else if (Regex.IsMatch(ef, @"\.json$", RegexOptions.IgnoreCase))
                {
                    if (!File.Exists(ef)) job.Errors.Add($"Edit-from sidecar not found: {ef}");
                }
                else if (VideoExts.Contains(Path.GetExtension(ef).ToLowerInvariant()))
                {
                    var side = Path.ChangeExtension(ef, ".json");
                    if (!File.Exists(side)) job.Errors.Add($"Edit-from video has no sidecar beside it: {side}");
                }
                // Anything else is treated as a literal interaction id at run time.
            }
        }

        private static bool? ParseOnOff(Job job, string label, string value)
        {
            switch (value.Trim().ToLowerInvariant())
            {
                case "on": return true;
                case "off": return false;
                default:
                    job.Errors.Add($"invalid {label} '{value}' (use on or off)");
                    return null;
            }
        }

        private static void SetEditFrom(Job job, string baseDir, string value)
        {
            var ef = value.Trim();
            if (Regex.IsMatch(ef, @"^#\d+$") ||
                !Regex.IsMatch(ef, @"[\\/]|\.(json|mp4|mov|webm|m4v)$", RegexOptions.IgnoreCase))
                job.EditFrom = ef;   // same-run ref or literal id
            else
                job.EditFrom = ResolveJobPath(baseDir, ef);
        }

        // -------------------------------------------------------------------
        // Input mode A: markdown catalogue parser
        // -------------------------------------------------------------------

        private static List<Job> ParseMarkdown(string[] lines, string baseDir)
        {
            var sections = new List<Job>();
            Job current = null;
            bool inFence = false;
            List<string> fenceLines = null;

            foreach (var line in lines)
            {
                var lead = line.TrimStart();

                if (inFence)
                {
                    if (lead.StartsWith("```"))
                    {
                        if (current != null)
                        {
                            var block = string.Join("\n", fenceLines).Trim();
                            if (block != "")
                                current.Prompt = current.Prompt == "" ? block : current.Prompt + "\n" + block;
                        }
                        inFence = false;
                        fenceLines = null;
                    }
                    else fenceLines.Add(line);
                    continue;
                }

                if (lead.StartsWith("```"))
                {
                    inFence = true;
                    fenceLines = new List<string>();
                    continue;
                }

                var h = Regex.Match(line, @"^(#{1,6})\s+(.*)$");
                if (h.Success)
                {
                    var level = h.Groups[1].Value.Length;
                    var text = h.Groups[2].Value.Trim();
                    if (level == 3)
                    {
                        current = new Job { Title = text };
                        sections.Add(current);
                    }
                    else if (level <= 2) current = null;
                    continue;
                }

                if (current == null) continue;

                var d = DirectiveRe.Match(line);
                if (d.Success)
                {
                    var label = d.Groups[1].Value.ToLowerInvariant();
                    var value = d.Groups[2].Value.Trim();
                    switch (label)
                    {
                        case "task": current.TaskExplicit = value.ToLowerInvariant(); break;
                        case "aspect": current.Aspect = value; break;
                        case "delivery": current.Delivery = value.ToLowerInvariant(); break;
                        case "image": current.Image = ResolveJobPath(baseDir, value); break;
                        case "ref": current.Refs.Add(ResolveJobPath(baseDir, value)); break;
                        case "source": current.Source = ResolveJobPath(baseDir, value); break;
                        case "edit-from": SetEditFrom(current, baseDir, value); break;
                        case "split": current.Split = ResolveJobPath(baseDir, value); break;
                        case "segment":
                            if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var segSecs) || segSecs <= 0)
                                current.Errors.Add($"invalid Segment '{value}' (use a whole number of seconds)");
                            else
                                current.SegmentSeconds = segSecs;
                            break;
                        case "walk": current.Walk = ParseOnOff(current, "Walk", value); break;
                        case "vision": current.Vision = ParseOnOff(current, "Vision", value); break;
                    }
                }
                // Ordinary prose / blockquote taglines are ignored.
            }

            var jobs = new List<Job>();
            var n = 0;
            foreach (var sec in sections)
            {
                if (sec.Prompt == "") continue;
                sec.Index = ++n;
                jobs.Add(sec);
            }
            foreach (var job in jobs)
            {
                ResolveJobTask(job);
                TestJobMedia(job, jobs.Count);
            }
            return jobs;
        }

        // -------------------------------------------------------------------
        // Input mode B: Claude-extracted JSON manifest
        // -------------------------------------------------------------------

        private static (List<Job> Jobs, string OutDir, string DisplayName) ReadManifest(string manifestPath)
        {
            var raw = File.ReadAllText(manifestPath, Encoding.UTF8);
            var mf = JsonNode.Parse(raw) as JsonObject;
            var baseDir = Path.GetDirectoryName(manifestPath) ?? ".";

            var mfJobs = mf?["jobs"] as JsonArray;
            if (mfJobs == null || mfJobs.Count == 0)
                throw new Exception($"Manifest '{manifestPath}' has no 'jobs' array.");

            var jobs = new List<Job>();
            var n = 0;
            foreach (var mjNode in mfJobs)
            {
                n++;
                var mj = mjNode as JsonObject;
                var prompt = mj?["prompt"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(prompt))
                    throw new Exception($"Manifest job {n} is missing a non-empty 'prompt'.");
                var title = mj["title"]?.GetValue<string>();
                var job = new Job
                {
                    Index = n,
                    Title = string.IsNullOrEmpty(title) ? $"job-{n}" : title,
                    Prompt = prompt.Trim(),
                };
                var v = mj["task"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.TaskExplicit = v.ToLowerInvariant();
                v = mj["aspectRatio"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.Aspect = v;
                v = mj["delivery"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.Delivery = v.ToLowerInvariant();
                v = mj["image"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.Image = ResolveJobPath(baseDir, v);
                if (mj["references"] is JsonArray refs)
                    foreach (var r in refs)
                        job.Refs.Add(ResolveJobPath(baseDir, r.GetValue<string>()));
                v = mj["sourceVideo"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.Source = ResolveJobPath(baseDir, v);
                v = mj["editFrom"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) SetEditFrom(job, baseDir, v);
                v = mj["split"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(v)) job.Split = ResolveJobPath(baseDir, v);
                if (mj["segmentSeconds"] != null) job.SegmentSeconds = mj["segmentSeconds"].GetValue<int>();
                if (mj["walk"] != null) job.Walk = mj["walk"].GetValue<bool>();
                if (mj["vision"] != null) job.Vision = mj["vision"].GetValue<bool>();
                jobs.Add(job);
            }
            foreach (var job in jobs)
            {
                ResolveJobTask(job);
                TestJobMedia(job, jobs.Count);
            }

            var outDir = mf["outputDir"]?.GetValue<string>();
            var srcFile = mf["sourceFile"]?.GetValue<string>();
            if (string.IsNullOrEmpty(outDir))
            {
                if (string.IsNullOrEmpty(srcFile))
                    throw new Exception("Manifest needs 'outputDir' or 'sourceFile' so the output folder is known.");
                var srcDir = Path.GetDirectoryName(srcFile);
                if (string.IsNullOrEmpty(srcDir)) srcDir = ".";
                outDir = Path.Combine(srcDir, OutputFolderName(Path.GetFileNameWithoutExtension(srcFile)));
            }

            var display = !string.IsNullOrEmpty(srcFile) ? Path.GetFileName(srcFile) : Path.GetFileName(manifestPath);
            return (jobs, outDir, display);
        }

        // -------------------------------------------------------------------
        // Gemini Omni Flash API
        // -------------------------------------------------------------------

        private static string FileIdFromUri(string uri)
        {
            var idx = uri.LastIndexOf("files/", StringComparison.Ordinal);
            var id = idx >= 0 ? uri.Substring(idx + 6) : uri;
            return id.Split('?', '#', ':')[0];
        }

        private static string ExtractApiError(string raw, int status)
        {
            try
            {
                var node = JsonNode.Parse(raw);
                var msg = node?["error"]?["message"]?.GetValue<string>()
                          ?? node?["error"]?["status"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(msg)) return msg;
            }
            catch { }
            return status >= 500 ? "Gemini had a server error - retry in a moment." : "Gemini rejected this request.";
        }

        private static async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, int timeoutSeconds)
        {
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds)))
            {
                try
                {
                    return await Http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cts.Token);
                }
                catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException)
                {
                    throw new Exception(NetworkErrorMsg);
                }
            }
        }

        private static string BuildRequestBody(
            Job job, string modelId, string effAspect, string effDelivery,
            bool store, string uploadedUri, string previousInteractionId)
        {
            JsonNode textItem() => new JsonObject { ["type"] = "text", ["text"] = job.Prompt };
            JsonNode imageItem(string imgPath) => new JsonObject
            {
                ["type"] = "image",
                ["data"] = Convert.ToBase64String(File.ReadAllBytes(imgPath)),
                ["mime_type"] = ImageMimes[Path.GetExtension(imgPath).ToLowerInvariant()],
            };

            JsonNode input;
            switch (job.Task)
            {
                case "text_to_video":
                    input = new JsonArray(textItem());
                    break;
                case "image_to_video":
                    input = new JsonArray(imageItem(job.Image), textItem());
                    break;
                case "reference_to_video":
                    // First-frame image first (binds <FIRST_FRAME>), then refs in
                    // order (bind <IMAGE_REF_0..> by array position), then the text.
                    var arr = new JsonArray { imageItem(job.Image) };
                    foreach (var r in job.Refs) arr.Add(imageItem(r));
                    arr.Add(textItem());
                    input = arr;
                    break;
                case "edit":
                    if (previousInteractionId != "")
                    {
                        input = JsonValue.Create(job.Prompt);   // plain-string input
                    }
                    else
                    {
                        // Live-API verified: must be type "video" with uri + mime_type.
                        // Sequence mode (Stage 3, unverified): a walked segment prepends
                        // the previous segment's last frame as a driving continuity image.
                        var editArr = new JsonArray();
                        if (job.Image != "") editArr.Add(imageItem(job.Image));
                        editArr.Add(new JsonObject
                        {
                            ["type"] = "video",
                            ["uri"] = uploadedUri,
                            ["mime_type"] = GetVideoMime(job.Source),
                        });
                        editArr.Add(textItem());
                        input = editArr;
                    }
                    break;
                default:
                    throw new Exception($"Unknown task {job.Task}.");
            }

            // Live-API verified: chained edits must omit generation_config, and
            // edits omit aspect_ratio (inherited from the source video).
            var responseFormat = new JsonObject { ["type"] = "video" };
            if (job.Task != "edit") responseFormat["aspect_ratio"] = effAspect;
            responseFormat["delivery"] = effDelivery;

            var body = new JsonObject
            {
                ["model"] = modelId,
                ["input"] = input,
            };
            if (previousInteractionId == "")
                body["generation_config"] = new JsonObject
                {
                    ["video_config"] = new JsonObject { ["task"] = job.Task }
                };
            body["response_format"] = responseFormat;
            body["background"] = false;
            body["store"] = store;
            body["stream"] = false;
            if (previousInteractionId != "")
                body["previous_interaction_id"] = previousInteractionId;

            return body.ToJsonString();
        }

        private static async Task<(string Raw, JsonNode Parsed)> CallInteraction(string bodyJson, string apiKey, Config cfg)
        {
            var request = new HttpRequestMessage(HttpMethod.Post, $"{cfg.EndpointBase.TrimEnd('/')}/interactions")
            {
                Content = new StringContent(bodyJson, Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("x-goog-api-key", apiKey);

            var resp = await SendAsync(request, cfg.TimeoutSeconds);
            var raw = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
                throw new Exception(ExtractApiError(raw, (int)resp.StatusCode));

            JsonNode parsed = null;
            try { parsed = JsonNode.Parse(raw); } catch { }
            return (raw, parsed);
        }

        private static bool IsVideoMap(JsonNode node)
        {
            if (!(node is JsonObject o)) return false;
            var type = o["type"]?.GetValue<string>();
            return type == "video" && (o.ContainsKey("data") || o.ContainsKey("uri"));
        }

        private static JsonNode SearchAnyVideo(JsonNode node)
        {
            if (node is JsonObject o)
            {
                if (IsVideoMap(o)) return o;
                foreach (var kv in o)
                {
                    var r = SearchAnyVideo(kv.Value);
                    if (r != null) return r;
                }
            }
            else if (node is JsonArray a)
            {
                foreach (var e in a)
                {
                    var r = SearchAnyVideo(e);
                    if (r != null) return r;
                }
            }
            return null;
        }

        private static JsonNode FindVideoItem(JsonNode parsed)
        {
            // steps[] -> content[] -> {type:video}; keep the LAST hit
            // (model_output follows user_input). Then output_video fallback,
            // then a tolerant recursive scan.
            JsonNode found = null;
            if (parsed?["steps"] is JsonArray steps)
                foreach (var step in steps)
                    if (step?["content"] is JsonArray content)
                        foreach (var item in content)
                            if (IsVideoMap(item)) found = item;
            if (found != null) return found;

            if (parsed?["output_video"] is JsonObject ov &&
                (ov.ContainsKey("data") || ov.ContainsKey("uri")))
                return ov;

            return parsed == null ? null : SearchAnyVideo(parsed);
        }

        private static async Task<string> WaitFileActive(
            string fileId, string apiKey, Config cfg,
            int intervalSeconds, int timeoutSeconds, string timeoutMessage)
        {
            var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            while (true)
            {
                try
                {
                    var request = new HttpRequestMessage(HttpMethod.Get,
                        $"{cfg.EndpointBase.TrimEnd('/')}/files/{fileId}");
                    request.Headers.Add("x-goog-api-key", apiKey);
                    var resp = await SendAsync(request, 60);
                    var raw = await resp.Content.ReadAsStringAsync();
                    if ((int)resp.StatusCode == 404)
                        throw new TerminalException("This generation's file expired server-side - retry to generate again.");
                    if (!resp.IsSuccessStatusCode)
                        throw new TerminalException(ExtractApiError(raw, (int)resp.StatusCode));

                    JsonNode info = null;
                    try { info = JsonNode.Parse(raw); } catch { }
                    var state = info?["state"]?.GetValue<string>() ?? "PROCESSING";
                    if (state == "ACTIVE")
                        return info?["downloadUri"]?.GetValue<string>()
                               ?? info?["download_uri"]?.GetValue<string>();
                    if (state == "FAILED")
                        throw new TerminalException(
                            info?["error"]?["message"]?.GetValue<string>() ?? "Generation failed server-side.");
                    // else PROCESSING - fall through to sleep
                }
                catch (TerminalException) { throw; }
                catch { /* transient network error - keep polling until the deadline */ }

                if (DateTime.UtcNow >= deadline) throw new TerminalException(timeoutMessage);
                await Task.Delay(TimeSpan.FromSeconds(intervalSeconds));
            }
        }

        private sealed class TerminalException : Exception
        {
            public TerminalException(string message) : base(message) { }
        }

        private static async Task Download(string url, string apiKey, string outFile, Config cfg)
        {
            try
            {
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Add("x-goog-api-key", apiKey);
                var resp = await SendAsync(request, cfg.TimeoutSeconds);
                if (!resp.IsSuccessStatusCode) throw new Exception();
                using (var fs = File.Create(outFile))
                {
                    await resp.Content.CopyToAsync(fs);
                }
            }
            catch
            {
                throw new Exception("Couldn't download the generated video.");
            }
        }

        private static async Task<string> FilesUpload(string filePath, string apiKey, Config cfg)
        {
            var bytes = File.ReadAllBytes(filePath);
            var mime = GetVideoMime(filePath);
            var displayName = Path.GetFileName(filePath);
            var startBody = new JsonObject
            {
                ["file"] = new JsonObject { ["display_name"] = displayName }
            }.ToJsonString();

            var start = new HttpRequestMessage(HttpMethod.Post, cfg.UploadEndpointBase)
            {
                Content = new StringContent(startBody, Encoding.UTF8, "application/json"),
            };
            start.Headers.Add("x-goog-api-key", apiKey);
            start.Headers.Add("X-Goog-Upload-Protocol", "resumable");
            start.Headers.Add("X-Goog-Upload-Command", "start");
            start.Headers.Add("X-Goog-Upload-Header-Content-Length", bytes.Length.ToString());
            start.Headers.Add("X-Goog-Upload-Header-Content-Type", mime);

            var startResp = await SendAsync(start, 120);
            if (!startResp.IsSuccessStatusCode)
                throw new Exception(ExtractApiError(await startResp.Content.ReadAsStringAsync(), (int)startResp.StatusCode));

            string uploadUrl = null;
            if (startResp.Headers.TryGetValues("x-goog-upload-url", out var vals))
                uploadUrl = vals.FirstOrDefault();
            if (string.IsNullOrEmpty(uploadUrl))
                throw new Exception("Upload session couldn't be started.");

            var upload = new HttpRequestMessage(HttpMethod.Post, uploadUrl)
            {
                Content = new ByteArrayContent(bytes),
            };
            upload.Headers.Add("X-Goog-Upload-Offset", "0");
            upload.Headers.Add("X-Goog-Upload-Command", "upload, finalize");

            var doneResp = await SendAsync(upload, cfg.TimeoutSeconds);
            var doneRaw = await doneResp.Content.ReadAsStringAsync();
            if (!doneResp.IsSuccessStatusCode)
                throw new Exception(ExtractApiError(doneRaw, (int)doneResp.StatusCode));

            JsonNode info = null;
            try { info = JsonNode.Parse(doneRaw); } catch { throw new Exception("Upload finished but the response was unreadable."); }
            var uri = info?["file"]?["uri"]?.GetValue<string>();
            if (string.IsNullOrEmpty(uri)) throw new Exception("Upload response had no file uri.");

            var fileId = FileIdFromUri(uri);
            await WaitFileActive(fileId, apiKey, cfg,
                cfg.UploadPollIntervalSeconds, cfg.UploadPollTimeoutSeconds,
                "Video upload processing timed out - retry the job.");
            return uri;
        }

        // -------------------------------------------------------------------
        // Sequence mode (Stage 3): FFmpeg split, batch expansion, prompt
        // walking with last-frame continuity. New ground - unverified against
        // the live API; the vision text-interaction shape below is best-effort,
        // modeled on the proven video-interaction shapes above.
        // -------------------------------------------------------------------

        private static (int ExitCode, string StdOut, string StdErr) RunTool(string exe, string args, string workingDir)
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = workingDir,
            };
            try
            {
                using (var p = Process.Start(psi))
                {
                    var stdout = p.StandardOutput.ReadToEnd();
                    var stderr = p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    return (p.ExitCode, stdout, stderr);
                }
            }
            catch (System.ComponentModel.Win32Exception)
            {
                throw new Exception($"'{exe}' not found. Set 'ffmpegPath'/'ffprobePath' in config.cfg or add ffmpeg/ffprobe to PATH.");
            }
        }

        private static double ProbeDuration(string ffprobePath, string inputPath)
        {
            var (code, stdout, stderr) = RunTool(ffprobePath,
                $"-v error -show_entries format=duration -of csv=p=0 \"{inputPath}\"",
                Path.GetDirectoryName(inputPath) ?? ".");
            var text = stdout.Trim();
            if (code != 0 || !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var dur) || dur <= 0)
                throw new Exception($"Could not read duration of '{inputPath}': " +
                    (stderr.Trim() != "" ? stderr.Trim() : "ffprobe returned no readable duration"));
            return dur;
        }

        private static List<string> SplitVideo(
            string ffmpegPath, string inputPath, string segmentsDir,
            int segmentSeconds, string baseName, bool force)
        {
            Directory.CreateDirectory(segmentsDir);
            var pattern = Path.Combine(segmentsDir, $"{baseName}-%03d.mp4");
            var existing = Directory.GetFiles(segmentsDir, $"{baseName}-*.mp4")
                .OrderBy(f => f, StringComparer.Ordinal).ToList();
            if (existing.Count > 0 && !force)
                return existing;
            foreach (var f in existing) File.Delete(f);

            var (code, _, stderr) = RunTool(ffmpegPath,
                $"-y -i \"{inputPath}\" -c copy -map 0 -segment_time {segmentSeconds} -f segment -reset_timestamps 1 \"{pattern}\"",
                segmentsDir);
            if (code != 0)
            {
                // Stream copy failed on a keyframe boundary - re-encode instead.
                var (code2, _, stderr2) = RunTool(ffmpegPath,
                    $"-y -i \"{inputPath}\" -c:v libx264 -preset veryfast -c:a aac -map 0 -segment_time {segmentSeconds} -f segment -reset_timestamps 1 \"{pattern}\"",
                    segmentsDir);
                if (code2 != 0)
                    throw new Exception($"ffmpeg could not split '{inputPath}': " +
                        (stderr2.Trim() != "" ? stderr2.Trim() : stderr.Trim()));
            }

            var produced = Directory.GetFiles(segmentsDir, $"{baseName}-*.mp4")
                .OrderBy(f => f, StringComparer.Ordinal).ToList();
            if (produced.Count == 0)
                throw new Exception($"ffmpeg produced no segments for '{inputPath}'.");
            return produced;
        }

        private static void ExtractLastFrame(string ffmpegPath, string videoPath, string outFramePath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(outFramePath) ?? ".");
            var (code, _, stderr) = RunTool(ffmpegPath,
                $"-y -sseof -0.05 -i \"{videoPath}\" -frames:v 1 -update 1 \"{outFramePath}\"",
                Path.GetDirectoryName(videoPath) ?? ".");
            if (code != 0 || !File.Exists(outFramePath))
                throw new Exception($"ffmpeg could not extract the last frame of '{videoPath}': {stderr.Trim()}");
        }

        private static bool IsTextMap(JsonNode node) =>
            node is JsonObject o && o["type"]?.GetValue<string>() == "text" && o["text"] != null;

        private static string FindTextItem(JsonNode parsed)
        {
            // Same walk-and-keep-last strategy as FindVideoItem, for a text response.
            string found = null;
            if (parsed?["steps"] is JsonArray steps)
                foreach (var step in steps)
                    if (step?["content"] is JsonArray content)
                        foreach (var item in content)
                            if (IsTextMap(item)) found = item["text"]?.GetValue<string>();
            return found ?? parsed?["output_text"]?.GetValue<string>();
        }

        private static async Task<string> DescribeFrame(string framePath, string modelId, string apiKey, Config cfg)
        {
            var body = new JsonObject
            {
                ["model"] = modelId,
                ["input"] = new JsonArray(
                    new JsonObject
                    {
                        ["type"] = "image",
                        ["data"] = Convert.ToBase64String(File.ReadAllBytes(framePath)),
                        ["mime_type"] = ImageMimes[Path.GetExtension(framePath).ToLowerInvariant()],
                    },
                    new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = "Describe this image in at most 60 words, focusing on scene, subject, and action, to help continue a video from this frame.",
                    }),
                ["response_format"] = new JsonObject { ["type"] = "text" },
                ["background"] = false,
                ["store"] = false,
                ["stream"] = false,
            };
            var (_, parsed) = await CallInteraction(body.ToJsonString(), apiKey, cfg);
            var text = parsed == null ? null : FindTextItem(parsed);
            return string.IsNullOrWhiteSpace(text) ? "" : text.Trim();
        }

        private static List<Job> ExpandSequences(List<Job> jobs, Config cfg, string outDir, int catalogWidth, bool dryRun, bool force)
        {
            var result = new List<Job>();
            foreach (var job in jobs)
            {
                if (job.Split == "" || job.Errors.Count > 0)
                {
                    result.Add(job);
                    continue;
                }

                var segmentSeconds = job.SegmentSeconds > 0 ? job.SegmentSeconds : cfg.GenerationSeconds;
                var walk = job.Walk ?? true;
                var vision = job.Vision ?? walk;
                var slug = Slugify(job.Title, cfg.SlugMaxLength);
                var parentNum = job.Index.ToString().PadLeft(catalogWidth, '0');
                var baseName = $"{parentNum}-{slug}";
                var segmentsDir = Path.Combine(outDir, "segments");
                var framesDir = Path.Combine(outDir, "frames");

                List<string> segmentPaths;
                try
                {
                    if (dryRun)
                    {
                        var duration = ProbeDuration(cfg.FfprobePath, job.Split);
                        var count = Math.Max(1, (int)Math.Ceiling(duration / segmentSeconds));
                        segmentPaths = new List<string>();
                        for (var k = 1; k <= count; k++)
                            segmentPaths.Add(Path.Combine(segmentsDir, $"{baseName}-{k:D3}.mp4"));
                    }
                    else
                    {
                        segmentPaths = SplitVideo(cfg.FfmpegPath, job.Split, segmentsDir, segmentSeconds, baseName, force);
                    }
                }
                catch (Exception ex)
                {
                    job.Errors.Add(ex.Message);
                    result.Add(job);
                    continue;
                }

                var segWidth = Math.Max(2, segmentPaths.Count.ToString().Length);
                for (var i = 0; i < segmentPaths.Count; i++)
                {
                    var k = i + 1;
                    var seg = new Job
                    {
                        Index = job.Index,
                        Title = job.Title,
                        Prompt = job.Prompt,
                        Task = "edit",
                        Aspect = job.Aspect,
                        Delivery = job.Delivery,
                        Source = segmentPaths[i],
                        IsSequenceSegment = true,
                        SeqParentIndex = job.Index,
                        SeqIndex = k,
                        SeqCount = segmentPaths.Count,
                        SeqSegmentPath = segmentPaths[i],
                        Walk = walk,
                        Vision = vision,
                    };
                    if (k > 1 && walk)
                        seg.SeqFramePath = Path.Combine(framesDir, $"{baseName}-{k.ToString().PadLeft(segWidth, '0')}-first.png");
                    result.Add(seg);
                }
            }
            return result;
        }

        // -------------------------------------------------------------------
        // Edit-from resolution
        // -------------------------------------------------------------------

        private static string SidecarInteractionId(string sidecarPath)
        {
            if (!File.Exists(sidecarPath))
                throw new Exception($"Edit-from sidecar not found: {sidecarPath}");
            var side = JsonNode.Parse(File.ReadAllText(sidecarPath, Encoding.UTF8));
            var id = side?["interactionId"]?.GetValue<string>()
                     ?? side?["interaction_id"]?.GetValue<string>();
            if (string.IsNullOrEmpty(id))
                throw new Exception("That output has no interaction id to chain from.");
            return id;
        }

        private static string ResolveEditFrom(
            string value, List<Job> allJobs, Dictionary<int, string> runResults,
            string outDir, int slugMaxLength, int numWidth)
        {
            var mHash = Regex.Match(value, @"^#(\d+)$");
            if (mHash.Success)
            {
                var n = int.Parse(mHash.Groups[1].Value);
                if (runResults.TryGetValue(n, out var id)) return id;
                var target = allJobs.FirstOrDefault(j => j.Index == n);
                if (target == null) throw new Exception($"Edit-from #{n} does not exist in this catalogue.");
                var slug = Slugify(target.Title, slugMaxLength);
                var side = Path.Combine(outDir, $"{n.ToString().PadLeft(numWidth, '0')}-{slug}.json");
                if (!File.Exists(side))
                    throw new Exception($"Job #{n} has not completed in this run and no sidecar was found at {side}");
                return SidecarInteractionId(side);
            }
            if (Regex.IsMatch(value, @"\.json$", RegexOptions.IgnoreCase))
                return SidecarInteractionId(value);
            if (VideoExts.Contains(Path.GetExtension(value).ToLowerInvariant()))
                return SidecarInteractionId(Path.ChangeExtension(value, ".json"));
            return value;   // literal interaction id
        }

        // -------------------------------------------------------------------
        // Generation queue
        // -------------------------------------------------------------------

        private static string TaskTag(string task)
        {
            switch (task)
            {
                case "text_to_video": return "[t2v]";
                case "image_to_video": return "[i2v]";
                case "reference_to_video": return "[r2v]";
                case "edit": return "[edit]";
                default: return "[?]";
            }
        }

        private static string MediaNote(Job job)
        {
            var bits = new List<string>();
            if (job.Aspect != "") bits.Add(job.Aspect);
            if (job.IsSequenceSegment) bits.Add($"seq {job.SeqIndex}/{job.SeqCount}");
            if (job.Image != "" && job.Refs.Count > 0) bits.Add($"image + {job.Refs.Count} refs");
            else if (job.Image != "") bits.Add($"image: {Path.GetFileName(job.Image)}");
            if (job.Source != "")
            {
                var size = File.Exists(job.Source)
                    ? string.Format(CultureInfo.CurrentCulture, " ({0:n1} MB)", new FileInfo(job.Source).Length / 1048576.0)
                    : "";
                bits.Add($"{(job.IsSequenceSegment ? "segment" : "upload")}: {Path.GetFileName(job.Source)}{size}");
            }
            if (job.IsSequenceSegment && job.SeqFramePath != "") bits.Add("first frame <- previous output");
            if (job.EditFrom != "") bits.Add($"chain: {job.EditFrom}");
            return bits.Count == 0 ? "" : "  " + string.Join("  ", bits);
        }

        private static async Task RunQueue(
            List<Job> jobs, string outDir, string displayName, Config cfg,
            string apiKey, string modelId, string defAspect, string defDelivery,
            int index, int limit, bool force, bool dryRun, Totals totals)
        {
            W("");
            W($"=== {displayName} ===", ConsoleColor.Cyan);

            if (jobs.Count == 0)
            {
                W($"WARNING: No jobs found in '{displayName}'.", ConsoleColor.Yellow);
                return;
            }

            // Catalog width is fixed by the pre-expansion job count, so NN numbering
            // (and Edit-from #N) stays stable regardless of how many segments a
            // Split job expands into.
            var catalogWidth = Math.Max(2, jobs.Count.ToString().Length);
            jobs = ExpandSequences(jobs, cfg, outDir, catalogWidth, dryRun, force);

            W($"Jobs: {jobs.Count}   ->   output: {outDir}", ConsoleColor.DarkGray);

            if (!dryRun && !Directory.Exists(outDir))
                Directory.CreateDirectory(outDir);

            var width = catalogWidth;
            var runResults = new Dictionary<int, string>();
            var seqLastOutput = new Dictionary<int, string>();

            var selected = jobs.AsEnumerable();
            if (index > 0)
            {
                selected = jobs.Where(j => j.Index == index).ToList();
                if (!selected.Any())
                {
                    W($"WARNING: No job at index {index} (set has {jobs.Count}).", ConsoleColor.Yellow);
                    return;
                }
            }
            if (limit > 0) selected = selected.Take(limit);

            foreach (var job in selected.ToList())
            {
                var slug = Slugify(job.Title, cfg.SlugMaxLength);
                string num;
                if (job.IsSequenceSegment)
                {
                    var segWidth = Math.Max(2, job.SeqCount.ToString().Length);
                    num = $"{job.Index.ToString().PadLeft(width, '0')}-{job.SeqIndex.ToString().PadLeft(segWidth, '0')}";
                }
                else
                {
                    num = job.Index.ToString().PadLeft(width, '0');
                }
                var baseName = $"{num}-{slug}";
                var tag = TaskTag(job.Task);
                var effAspect = job.Aspect != "" ? job.Aspect : defAspect;
                var effDelivery = job.Delivery != "" ? job.Delivery : defDelivery;

                if (dryRun)
                {
                    W(string.Format("  [{0}] {1,-34} {2}{3}", num, job.Title, tag, MediaNote(job)), ConsoleColor.White);
                    W($"        -> {baseName}.mp4   ({job.Prompt.Length} chars)", ConsoleColor.DarkGray);
                    if (job.Errors.Count > 0)
                    {
                        foreach (var e in job.Errors) W($"        !! {e}", ConsoleColor.Red);
                        totals.Failed++;
                    }
                    else totals.Planned++;
                    continue;
                }

                var outFile = Path.Combine(outDir, $"{baseName}.mp4");
                if (File.Exists(outFile) && !force)
                {
                    W($"  [{num}] SKIP (exists): {baseName}.mp4", ConsoleColor.Yellow);
                    totals.Skipped++;
                    continue;
                }

                W(string.Format("  [{0}] {1,-34} {2}", num, job.Title, tag), ConsoleColor.White);

                if (job.Errors.Count > 0)
                {
                    foreach (var e in job.Errors) W($"        FAILED: {e}", ConsoleColor.Red);
                    totals.Failed++;
                    continue;
                }

                var sw = Stopwatch.StartNew();

                var previousId = "";
                if (job.EditFrom != "")
                {
                    try
                    {
                        previousId = ResolveEditFrom(job.EditFrom, jobs, runResults, outDir, cfg.SlugMaxLength, width);
                    }
                    catch (Exception ex)
                    {
                        W($"        FAILED: {ex.Message}", ConsoleColor.Red);
                        totals.Failed++;
                        continue;
                    }
                }

                // Sequence walk (Stage 3): drive segment k>1 from the last successful
                // segment's output - the in-run cache first, then a resume-safe scan
                // of disk for the nearest earlier segment that already completed.
                if (job.IsSequenceSegment && job.SeqIndex > 1 && (job.Walk ?? true))
                {
                    string driveSrc = null;
                    if (seqLastOutput.TryGetValue(job.SeqParentIndex, out var cached) && File.Exists(cached))
                        driveSrc = cached;
                    else
                    {
                        var segWidthLocal = Math.Max(2, job.SeqCount.ToString().Length);
                        var parentNumStr = job.Index.ToString().PadLeft(width, '0');
                        for (var j = job.SeqIndex - 1; j >= 1 && driveSrc == null; j--)
                        {
                            var candidate = Path.Combine(outDir,
                                $"{parentNumStr}-{slug}-{j.ToString().PadLeft(segWidthLocal, '0')}.mp4");
                            if (File.Exists(candidate)) driveSrc = candidate;
                        }
                    }

                    if (driveSrc != null)
                    {
                        try
                        {
                            ExtractLastFrame(cfg.FfmpegPath, driveSrc, job.SeqFramePath);
                            job.Image = job.SeqFramePath;
                            if (job.Vision ?? true)
                            {
                                W("        describing last frame...", ConsoleColor.DarkGray);
                                job.SeqVisionText = await DescribeFrame(job.SeqFramePath, modelId, apiKey, cfg);
                                if (job.SeqVisionText != "")
                                    job.Prompt = $"{job.Prompt}\nContinue from this scene: {job.SeqVisionText}";
                            }
                        }
                        catch (Exception ex)
                        {
                            W($"        FAILED: {ex.Message}", ConsoleColor.Red);
                            totals.Failed++;
                            continue;
                        }
                    }
                }

                var partFile = outFile + ".part";
                if (File.Exists(partFile)) File.Delete(partFile);

                var attempt = 0;
                var succeeded = false;
                var uploadedUri = "";
                string interactionId = null;
                string fileId = null;

                while (true)
                {
                    attempt++;
                    try
                    {
                        if (job.Source != "" && uploadedUri == "")
                        {
                            var srcMb = string.Format(CultureInfo.CurrentCulture, "{0:n1}",
                                new FileInfo(job.Source).Length / 1048576.0);
                            W($"        uploading {Path.GetFileName(job.Source)} ({srcMb} MB)...", ConsoleColor.DarkGray);
                            var upSw = Stopwatch.StartNew();
                            uploadedUri = await FilesUpload(job.Source, apiKey, cfg);
                            upSw.Stop();
                            W(string.Format(CultureInfo.CurrentCulture, "        uploaded ({0}, {1:n1}s)",
                                FileIdFromUri(uploadedUri), upSw.Elapsed.TotalSeconds), ConsoleColor.DarkGray);
                        }

                        var bodyJson = BuildRequestBody(job, modelId, effAspect, effDelivery,
                            cfg.Store, uploadedUri, previousId);

                        W("        generating...", ConsoleColor.DarkGray);
                        var (raw, parsed) = await CallInteraction(bodyJson, apiKey, cfg);

                        interactionId = parsed?["id"]?.GetValue<string>();

                        var statusField = parsed?["status"]?.GetValue<string>();
                        if (statusField == "failed" || statusField == "error" || statusField == "cancelled")
                        {
                            throw new Exception(
                                parsed?["error"]?["message"]?.GetValue<string>()
                                ?? "Gemini reported the generation failed.");
                        }

                        var video = parsed == null ? null : FindVideoItem(parsed);
                        if (video == null)
                        {
                            if (cfg.SaveResponseJson)
                            {
                                var dump = Path.Combine(outDir, $"{baseName}-response.json");
                                File.WriteAllText(dump, raw, Encoding.UTF8);
                                throw new Exception($"Gemini's response didn't include a video - raw response saved to {dump} for inspection.");
                            }
                            throw new Exception("Gemini returned no video in its response.");
                        }

                        fileId = null;
                        var data = (video as JsonObject)?["data"]?.GetValue<string>();
                        if (!string.IsNullOrEmpty(data))
                        {
                            File.WriteAllBytes(partFile, Convert.FromBase64String(data));
                        }
                        else
                        {
                            var uri = (video as JsonObject)?["uri"]?.GetValue<string>() ?? "";
                            fileId = FileIdFromUri(uri);
                            W($"        polling files/{fileId}...", ConsoleColor.DarkGray);
                            var pollSw = Stopwatch.StartNew();
                            string downloadUri;
                            try
                            {
                                downloadUri = await WaitFileActive(fileId, apiKey, cfg,
                                    cfg.PollIntervalSeconds, cfg.PollTimeoutSeconds,
                                    "Generation is taking longer than expected - check back later or retry.");
                            }
                            catch (TerminalException tex) { throw new Exception(tex.Message); }
                            pollSw.Stop();
                            W(string.Format(CultureInfo.CurrentCulture, "        ACTIVE after {0:n0}s, downloading...",
                                pollSw.Elapsed.TotalSeconds), ConsoleColor.DarkGray);
                            if (string.IsNullOrEmpty(downloadUri))
                                downloadUri = $"{cfg.EndpointBase.TrimEnd('/')}/files/{fileId}:download?alt=media";
                            await Download(downloadUri, apiKey, partFile, cfg);
                        }

                        // Atomic completion: video into place, then the sidecar.
                        File.Move(partFile, outFile, true);
                        succeeded = true;
                        break;
                    }
                    catch (Exception ex)
                    {
                        var msg = ex.Message;
                        if (File.Exists(partFile)) { try { File.Delete(partFile); } catch { } }
                        // Deterministic input-safety blocks can never pass on retry.
                        var nonRetryable = Regex.IsMatch(msg, "input blocked|prohibited use policy", RegexOptions.IgnoreCase);
                        if (nonRetryable || attempt > cfg.MaxRetries)
                        {
                            W($"        FAILED: {msg}", ConsoleColor.Red);
                            totals.Failed++;
                            break;
                        }
                        var backoff = Math.Min(30, 3 * attempt);
                        W($"        attempt {attempt} failed: {msg} - retrying in {backoff}s", ConsoleColor.DarkYellow);
                        await Task.Delay(TimeSpan.FromSeconds(backoff));
                    }
                }

                if (!succeeded) continue;
                sw.Stop();

                if (!string.IsNullOrEmpty(interactionId)) runResults[job.Index] = interactionId;
                if (job.IsSequenceSegment) seqLastOutput[job.SeqParentIndex] = outFile;

                if (cfg.SaveJobSidecar)
                {
                    var refsArr = new JsonArray();
                    foreach (var r in job.Refs) refsArr.Add(r);
                    var sidecar = new JsonObject
                    {
                        ["title"] = job.Title,
                        ["index"] = job.Index,
                        ["task"] = job.Task,
                        ["prompt"] = job.Prompt,
                        ["model"] = modelId,
                        ["aspectRatio"] = job.Task == "edit" ? null : (JsonNode)effAspect,
                        ["delivery"] = effDelivery,
                        ["interactionId"] = interactionId != null ? (JsonNode)interactionId : null,
                        ["fileId"] = fileId != null ? (JsonNode)fileId : null,
                        ["previousInteractionId"] = previousId != "" ? (JsonNode)previousId : null,
                        ["image"] = job.Image != "" ? (JsonNode)job.Image : null,
                        ["references"] = refsArr,
                        ["sourceVideo"] = job.Source != "" ? (JsonNode)job.Source : null,
                        ["videoFile"] = $"{baseName}.mp4",
                        ["createdAt"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
                        ["elapsedSeconds"] = Math.Round(sw.Elapsed.TotalSeconds, 1),
                        ["status"] = "completed",
                    };
                    if (job.IsSequenceSegment)
                    {
                        sidecar["sequence"] = new JsonObject
                        {
                            ["parent"] = job.SeqParentIndex,
                            ["index"] = job.SeqIndex,
                            ["count"] = job.SeqCount,
                            ["segmentPath"] = job.SeqSegmentPath,
                            ["firstFramePath"] = job.SeqFramePath != "" ? (JsonNode)job.SeqFramePath : null,
                            ["visionText"] = job.SeqVisionText != "" ? (JsonNode)job.SeqVisionText : null,
                        };
                    }
                    File.WriteAllText(Path.Combine(outDir, $"{baseName}.json"),
                        sidecar.ToJsonString(new JsonSerializerOptions { WriteIndented = true }),
                        Encoding.UTF8);
                }

                var sizeKb = Math.Round(new FileInfo(outFile).Length / 1024.0, 0);
                W(string.Format(CultureInfo.CurrentCulture, "        OK  {0}.mp4  ({1:n0} KB, {2:n1}s)",
                    baseName, sizeKb, sw.Elapsed.TotalSeconds), ConsoleColor.Green);
                totals.Generated++;

                if (cfg.DelayBetweenJobsSeconds > 0)
                    await Task.Delay(TimeSpan.FromSeconds(cfg.DelayBetweenJobsSeconds));
            }
        }

        // -------------------------------------------------------------------
        // Main
        // -------------------------------------------------------------------

        private static async Task<int> Main(string[] args)
        {
            string path = null, manifest = null, configPath = null, model = null;
            string aspectRatio = null, delivery = null, apiKey = null;
            int index = 0, limit = 0;
            bool force = false, dryRun = false, recurse = false;

            try
            {
                for (var i = 0; i < args.Length; i++)
                {
                    var a = args[i];
                    string Next()
                    {
                        if (i + 1 >= args.Length) throw new Exception($"Missing value for {a}.");
                        return args[++i];
                    }
                    switch (a.ToLowerInvariant())
                    {
                        case "-path": path = Next(); break;
                        case "-manifest": manifest = Next(); break;
                        case "-configpath": configPath = Next(); break;
                        case "-index": index = int.Parse(Next()); break;
                        case "-limit": limit = int.Parse(Next()); break;
                        case "-model": model = Next(); break;
                        case "-aspectratio":
                            aspectRatio = Next();
                            if (aspectRatio != "16:9" && aspectRatio != "9:16")
                                throw new Exception("-AspectRatio must be 16:9 or 9:16.");
                            break;
                        case "-delivery":
                            delivery = Next().ToLowerInvariant();
                            if (delivery != "inline" && delivery != "uri")
                                throw new Exception("-Delivery must be inline or uri.");
                            break;
                        case "-apikey": apiKey = Next(); break;
                        case "-force": force = true; break;
                        case "-dryrun": dryRun = true; break;
                        case "-recurse": recurse = true; break;
                        default:
                            if (!a.StartsWith("-") && path == null) { path = a; break; }
                            throw new Exception($"Unknown argument: {a}");
                    }
                }

                var cfg = LoadConfig(configPath);
                var effModel = model ?? cfg.Model;
                var effAspect = aspectRatio ?? cfg.DefaultAspectRatio;
                var effDelivery = delivery ?? cfg.DefaultDelivery;

                var effKey = apiKey;
                if (string.IsNullOrEmpty(effKey)) effKey = cfg.ApiKey;
                if (string.IsNullOrEmpty(effKey)) effKey = Environment.GetEnvironmentVariable("GEMINI_API_KEY");
                if (string.IsNullOrEmpty(effKey)) effKey = Environment.GetEnvironmentVariable("OMNI_API_KEY");

                if (!dryRun && string.IsNullOrWhiteSpace(effKey))
                    throw new Exception("No API key. Set 'apiKey' in config.cfg, pass -ApiKey, or set $env:GEMINI_API_KEY / $env:OMNI_API_KEY.");

                if (manifest != null && path != null)
                    throw new Exception("Provide either -Path or -Manifest, not both.");
                if (manifest == null && path == null)
                    throw new Exception("Provide -Path <markdown-or-folder> or -Manifest <json>.");

                var modeLabel = manifest != null ? "MANIFEST (Claude-extracted)" : "MARKDOWN";
                W("Omni Producer", ConsoleColor.Magenta);
                W($"Model: {effModel}   Aspect: {effAspect}   Delivery: {effDelivery}   Mode: {modeLabel}   {(dryRun ? "DRY-RUN" : "GENERATE")}",
                    ConsoleColor.DarkGray);

                var totals = new Totals();

                if (manifest != null)
                {
                    var mfPath = Path.GetFullPath(manifest);
                    if (!File.Exists(mfPath)) throw new Exception($"Manifest not found: {manifest}");
                    var (jobs, outDir, display) = ReadManifest(mfPath);
                    await RunQueue(jobs, outDir, display, cfg, effKey, effModel,
                        effAspect, effDelivery, index, limit, force, dryRun, totals);
                }
                else
                {
                    var full = Path.GetFullPath(path);
                    List<string> files;
                    if (Directory.Exists(full))
                    {
                        files = Directory.GetFiles(full, "*.md",
                            recurse ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly)
                            .OrderBy(f => f, StringComparer.Ordinal).ToList();
                    }
                    else if (File.Exists(full)) files = new List<string> { full };
                    else throw new Exception($"No .md files found at '{path}'.");

                    if (files.Count == 0) throw new Exception($"No .md files found at '{path}'.");

                    foreach (var f in files)
                    {
                        var lines = File.ReadAllLines(f, Encoding.UTF8);
                        var jobs = ParseMarkdown(lines, Path.GetDirectoryName(f) ?? ".");
                        var outDir = Path.Combine(Path.GetDirectoryName(f) ?? ".",
                            OutputFolderName(Path.GetFileNameWithoutExtension(f)));
                        await RunQueue(jobs, outDir, Path.GetFileName(f), cfg, effKey, effModel,
                            effAspect, effDelivery, index, limit, force, dryRun, totals);
                    }
                }

                W("");
                if (dryRun)
                {
                    W($"Dry run complete. {totals.Planned} job(s) would be generated.", ConsoleColor.Magenta);
                    if (totals.Failed > 0)
                    {
                        W($"{totals.Failed} job(s) have validation errors (marked !!).", ConsoleColor.Red);
                        return 1;
                    }
                    return 0;
                }
                W($"Done. Generated: {totals.Generated}  Skipped: {totals.Skipped}  Failed: {totals.Failed}", ConsoleColor.Magenta);
                return totals.Failed > 0 ? 1 : 0;
            }
            catch (Exception ex)
            {
                W(ex.Message, ConsoleColor.Red);
                return 1;
            }
        }
    }
}
