using System.Text.Json;

namespace Wootc.Shell.Native;

// Diagnostic only: the matching authenticated response remains a failure.
internal sealed class StorageObservationFailure : IOException
{
    internal string Projection { get; }
    private StorageObservationFailure(string projection) : base("Native configuration observation refused") => Projection = projection;
    internal static StorageObservationFailure Decode(JsonElement data)
    {
        string[] fields = ["callPhase", "callMilliseconds", "phaseTimings","schemaVersion", "kind", "phase", "auditStage", "contextState", "commandAttempted", "commandStarted", "waitCompleted", "commandPid", "exitCode", "deadlineExceeded", "auditMilliseconds", "commandMilliseconds"];
        if (data.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Storage diagnostic refused");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in data.EnumerateObject()) if (!fields.Contains(field.Name, StringComparer.Ordinal) || !seen.Add(field.Name)) throw new InvalidDataException("Storage diagnostic refused");
        if (seen.Count != fields.Length || data.GetProperty("schemaVersion").GetInt32() != 1 || data.GetProperty("kind").GetString() != "storage-observation") throw new InvalidDataException("Storage diagnostic refused");
        string phase = data.GetProperty("phase").GetString() ?? "";
        string audit = data.GetProperty("auditStage").GetString() ?? "";
        string context = data.GetProperty("contextState").GetString() ?? "";
        if (phase is not ("no-child-phase-observed" or "load-cim-assemblies" or "import-utility" or "import-cim" or "import-storage" or "import-bitlocker" or "read-volumes" or "read-partition" or "read-disk" or "read-protection" or "serialize") || audit is not ("not-started" or "kernel-directories" or "storage-assembly" or "cim-assemblies" or "interpreter" or "storage-module" or "bitlocker-module" or "utility-module" or "cim-module" or "complete") || context is not ("active" or "canceled" or "deadline" or "unavailable")) throw new InvalidDataException("Storage diagnostic refused");
        bool attempted=data.GetProperty("commandAttempted").GetBoolean(), started=data.GetProperty("commandStarted").GetBoolean(), waited=data.GetProperty("waitCompleted").GetBoolean(), deadline=data.GetProperty("deadlineExceeded").GetBoolean();
        int pid=data.GetProperty("commandPid").GetInt32(), exit=data.GetProperty("exitCode").GetInt32();
        long auditMs=data.GetProperty("auditMilliseconds").GetInt64(), commandMs=data.GetProperty("commandMilliseconds").GetInt64();
        if (pid<0 || auditMs<0 || commandMs<0 || auditMs>60000 || commandMs>60000 || auditMs+commandMs>60000 || (started && (!attempted || pid==0)) || (!started && pid!=0) || (waited && !started) || (!attempted && commandMs!=0) || (!waited && exit!=-1) || (deadline != (context=="deadline")) || (!started && phase!="no-child-phase-observed")) throw new InvalidDataException("Storage diagnostic refused");
        string[] phases=["root-enumeration","initial-selection","storage-first-query","storage-capacity","metadata-read","metadata-root-audit","catalogue-policy","metadata-revalidation","storage-second-query","storage-identity-reread","final-selection"];
        string callPhase=data.GetProperty("callPhase").GetString()??"";
        long callMs=data.GetProperty("callMilliseconds").GetInt64();
        var timings=data.GetProperty("phaseTimings");var phaseSeen=new HashSet<string>(StringComparer.Ordinal);long sum=0;
        if(timings.ValueKind!=JsonValueKind.Object || callMs<0 || callMs>60000 || (callPhase!="standalone-query" && !phases.Contains(callPhase,StringComparer.Ordinal))) throw new InvalidDataException("Storage diagnostic refused");
        var projected=new List<string>();
        foreach(var item in timings.EnumerateObject()) {long ms=item.Value.GetInt64();if(!phases.Contains(item.Name,StringComparer.Ordinal)||!phaseSeen.Add(item.Name)||ms<0||ms>60000)throw new InvalidDataException("Storage diagnostic refused");sum+=ms;projected.Add($"{item.Name}:{ms}");}
        if(phaseSeen.Count!=phases.Length||sum>callMs||callMs-sum>256)throw new InvalidDataException("Storage diagnostic refused");
        return new($"CallPhase:{callPhase}; CallMs:{callMs}; Spans:{string.Join(",",projected)}; StoragePhase:{phase}; Audit:{audit}; Context:{context}; Attempted:{attempted}; Started:{started}; Waited:{waited}; Pid:{pid}; Exit:{exit}; Deadline:{deadline}; AuditMs:{auditMs}; CommandMs:{commandMs}");
    }
}
