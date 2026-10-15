package main
import("bufio";"context";"fmt";"io";"testing";"time")
func TestMissingCapabilityReturnMustRefuse(t *testing.T){
 childIn,parentIn:=io.Pipe();parentOut,childOut:=io.Pipe();defer childIn.Close();defer parentIn.Close();defer childOut.Close();defer parentOut.Close()
 go func(){fmt.Fprintln(childOut,`{"QMP":{"version":{},"capabilities":[]}}`);r:=bufio.NewScanner(childIn);if r.Scan(){fmt.Fprintln(childOut,`{"id":"1"}`)}}()
 ctx,cancel:=context.WithTimeout(context.Background(),time.Second);defer cancel();if _,err:=connectQMP(ctx,parentIn,parentOut);err==nil{t.Fatal("missing capability return accepted as successful negotiation")}
}
