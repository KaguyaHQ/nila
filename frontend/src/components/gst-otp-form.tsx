import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";

export function GstOtpForm({
  challenge,
  username,
  setUsername,
  otp,
  setOtp,
  pending,
  error,
  onSubmit,
  onReset,
  verifyLabel,
}: {
  challenge: boolean;
  username: string;
  setUsername: (value: string) => void;
  otp: string;
  setOtp: (value: string) => void;
  pending: boolean;
  error?: string | null;
  onSubmit: () => void;
  onReset: () => void;
  verifyLabel: string;
}) {
  return (
    <>
      <DialogHeader>
        <DialogTitle>{challenge ? "Enter GST verification code" : "Connect GST"}</DialogTitle>
        <DialogDescription>
          {challenge
            ? "Enter the six-digit OTP sent to the mobile number and email registered with GST."
            : "Use this client’s GST portal username. We’ll send an OTP to verify the connection."}
        </DialogDescription>
      </DialogHeader>

      <form
        className="space-y-4"
        onSubmit={(event) => {
          event.preventDefault();
          onSubmit();
        }}
      >
        {challenge ? (
          <div className="space-y-2">
            <Label htmlFor="gst-otp">Verification code</Label>
            <Input
              id="gst-otp"
              autoFocus
              required
              disabled={pending}
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]{6}"
              maxLength={6}
              value={otp}
              onChange={(event) => setOtp(event.target.value.replace(/\D/g, ""))}
            />
          </div>
        ) : (
          <div className="space-y-2">
            <Label htmlFor="gst-username">GST username</Label>
            <Input
              id="gst-username"
              autoFocus
              required
              maxLength={100}
              disabled={pending}
              autoComplete="username"
              value={username}
              onChange={(event) => setUsername(event.target.value)}
            />
          </div>
        )}

        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}

        <Button
          type="submit"
          className="w-full"
          disabled={pending || (challenge ? otp.length !== 6 : !username.trim())}
        >
          {pending ? "Please wait…" : challenge ? verifyLabel : "Send OTP"}
        </Button>

        {challenge && (
          <Button
            type="button"
            variant="ghost"
            className="w-full"
            disabled={pending}
            onClick={onReset}
          >
            Use another username or resend OTP
          </Button>
        )}
      </form>
    </>
  );
}
