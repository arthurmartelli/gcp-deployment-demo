FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY mcp_server.py /app/mcp_server.py

ENV PYTHONPATH=/app

EXPOSE 8080

CMD ["python", "mcp_server.py"]
