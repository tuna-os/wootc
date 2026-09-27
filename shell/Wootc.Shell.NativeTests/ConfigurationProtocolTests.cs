using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class ConfigurationProtocolTests
{
    private static NativeConfigurationSnapshot Observed() => new()
    {
        SchemaVersion=1, BrandId="wootc", RootScope="none", RootBinding="", CatalogueSource="embedded",
        CatalogueMetadataSha256=new string('a',64), PolicySource="default",
        Policy=new() { Channel="alpha", Reason="Observed policy" }, Branding=new() { ProductName="wootc", Name="Fixture", Catalog=new() },
        Defaults=new() { DiskSizeGB=40, Encryption="tpm2-luks", Bootloader="auto" },
        Bundle=new() { State="absent" }, StorageStatus="not-observed", Steps=new(), Storage=new(),
        Images=new() { new() { Admitted=true, Image=new() { Id="fixture",Name="Observed image",ImageRef="ghcr.io/tuna-os/fixture:latest",Status="green" } } }
    };

    [Fact]
    public void CompleteObservedConfigurationKeepsAuthorizationAndIntegrityFalse()
    {
        var result=NativeConfigurationProtocol.Decode(JsonSerializer.SerializeToElement(Observed()), "wootc");
        Assert.False(result.InstallAuthorized); Assert.False(result.OriginalUserCaptured);
        Assert.Empty(result.Storage); Assert.False(result.Images[0].ContentVerified);
        Assert.Equal("tpm2-luks",result.Defaults.Encryption);
    }

    [Fact]
    public void SelfConsistentForeignSnapshotCannotReplaceAuthenticatedBrand()
    {
        var snapshot=Observed(); snapshot.BrandId="foreign";
        Assert.Throws<InvalidDataException>(()=>NativeConfigurationProtocol.Decode(JsonSerializer.SerializeToElement(snapshot),"wootc"));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("null")]
    [InlineData("{\"schemaVersion\":1}")]
    public void MissingObservationCannotBecomeDefaultConfiguration(string json)
    {
        using var document=JsonDocument.Parse(json);
        Assert.Throws<InvalidDataException>(()=>NativeConfigurationProtocol.Decode(document.RootElement,"wootc"));
    }

    [Fact]
    public void DuplicateNestedUnknownAndFalseAuthorityAreRefused()
    {
        string json=JsonSerializer.Serialize(Observed());
        using var duplicate=JsonDocument.Parse(json.Replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"));
        Assert.Throws<InvalidDataException>(()=>NativeConfigurationProtocol.Decode(duplicate.RootElement,"wootc"));
        foreach (string change in new[]{"unknown","missing-image","null-defaults","authorization","integrity","physical-proxy"})
        {
            var node=JsonNode.Parse(json)!.AsObject();
            switch(change)
            {
                case "unknown":node["policy"]!["unexpected"]=true;break;
                case "missing-image":node["images"]![0]!["image"]!.AsObject().Remove("imageRef");break;
                case "null-defaults":node["defaults"]=null;break;
                case "authorization":node["installAuthorized"]=true;break;
                case "integrity":node["images"]![0]!["contentVerified"]=true;break;
                case "physical-proxy":node["rootScope"]="payload";node["rootBinding"]="F";break;
            }
            using var modified=JsonDocument.Parse(node.ToJsonString());
            Assert.Throws<InvalidDataException>(()=>NativeConfigurationProtocol.Decode(modified.RootElement,"wootc"));
        }
    }
}
