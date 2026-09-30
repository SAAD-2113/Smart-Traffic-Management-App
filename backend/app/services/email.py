import asyncio
import logging
import smtplib
from collections import deque
from dataclasses import dataclass
from email.message import EmailMessage as MimeMessage
from typing import Protocol

from app.core.config import get_settings

logger = logging.getLogger("app.email")


@dataclass(frozen=True)
class EmailMessage:
    to: str
    subject: str
    body: str


class EmailSender(Protocol):
    async def send(self, message: EmailMessage) -> None: ...


class ConsoleEmailSender:
    """Development/test only: prints the email to the backend console. Refused in production."""

    outbox: deque[EmailMessage] = deque(maxlen=50)

    async def send(self, message: EmailMessage) -> None:
        self.outbox.append(message)
        logger.warning("DEV EMAIL to %s | %s\n%s", message.to, message.subject, message.body)


class SmtpEmailSender:
    async def send(self, message: EmailMessage) -> None:
        await asyncio.to_thread(self._send_blocking, message)

    @staticmethod
    def _send_blocking(message: EmailMessage) -> None:
        s = get_settings()
        mime = MimeMessage()
        mime["From"] = s.smtp_from
        mime["To"] = message.to
        mime["Subject"] = message.subject
        mime.set_content(message.body)
        with smtplib.SMTP(s.smtp_host, s.smtp_port, timeout=15) as smtp:
            smtp.starttls()
            if s.smtp_username and s.smtp_password:
                smtp.login(s.smtp_username, s.smtp_password.get_secret_value())
            smtp.send_message(mime)


def get_email_sender() -> EmailSender:
    return SmtpEmailSender() if get_settings().smtp_host else ConsoleEmailSender()
