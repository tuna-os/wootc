package main

import "testing"

func TestRecoveryTaskIdentityMatchesOnlyOwnedTask(t *testing.T) {
	expected := recoveryTaskIdentity{
		Name:         "wootc-recovery",
		Executable:   `C:\wootc\install\wootc.exe`,
		Arguments:    "recover --startup",
		Principal:    "SYSTEM",
		PrincipalSID: "S-1-5-18",
		RunLevel:     "Highest",
		Trigger:      "MSFT_TaskBootTrigger",
		ActionCount:  1,
		TriggerCount: 1,
	}

	tests := []struct {
		name   string
		mutate func(*recoveryTaskIdentity)
		want   bool
	}{
		{name: "exact identity", want: true},
		{
			name: "scheduler normalizes case and executable quoting",
			mutate: func(actual *recoveryTaskIdentity) {
				actual.Name = "WOOTC-RECOVERY"
				actual.Executable = `"c:\WOOTC\INSTALL\wootc.exe"`
				actual.Principal = "system"
				actual.RunLevel = "highest"
				actual.Trigger = "msft_taskboottrigger"
			},
			want: true,
		},
		{
			name:   "different executable is foreign",
			mutate: func(actual *recoveryTaskIdentity) { actual.Executable = `C:\Users\Public\wootc.exe` },
		},
		{
			name:   "different arguments are foreign",
			mutate: func(actual *recoveryTaskIdentity) { actual.Arguments = "recover --prompt" },
		},
		{
			name: "different principal is foreign",
			mutate: func(actual *recoveryTaskIdentity) {
				actual.Principal = "BUILTIN\\Users"
				actual.PrincipalSID = "S-1-5-32-545"
			},
		},
		{
			name: "different principal whose SID differs is foreign",
			mutate: func(actual *recoveryTaskIdentity) {
				actual.Principal = "Users"
				actual.PrincipalSID = "S-1-5-32-545"
			},
		},
		{
			name: "principal reported by another name but the same SID is ours",
			mutate: func(actual *recoveryTaskIdentity) {
				actual.Principal = "NT AUTHORITY\\SYSTEM"
				actual.PrincipalSID = "S-1-5-18"
			},
			want: true,
		},
		{
			name: "an unresolved principal name proves nothing",
			mutate: func(actual *recoveryTaskIdentity) {
				actual.Principal = "LocalSystem"
				actual.PrincipalSID = ""
			},
		},
		{
			name:   "different trigger is foreign",
			mutate: func(actual *recoveryTaskIdentity) { actual.Trigger = "MSFT_TaskLogonTrigger" },
		},
		{
			name:   "extra action is foreign",
			mutate: func(actual *recoveryTaskIdentity) { actual.ActionCount = 2 },
		},
		{
			name:   "extra trigger is foreign",
			mutate: func(actual *recoveryTaskIdentity) { actual.TriggerCount = 2 },
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual := expected
			if test.mutate != nil {
				test.mutate(&actual)
			}
			if got := recoveryTaskIdentityMatches(actual, expected); got != test.want {
				t.Errorf("recoveryTaskIdentityMatches() = %v, want %v\nactual: %+v\nexpected: %+v", got, test.want, actual, expected)
			}
		})
	}
}
