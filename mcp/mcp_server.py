import json
import os

import uvicorn
from google.cloud import bigquery
from mcp.server.fastmcp import FastMCP
from mcp.server.sse import SseServerTransport
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.routing import Mount, Route

mcp = FastMCP("HR Tool")

APP_HOST = os.environ.get("APP_HOST", "0.0.0.0")
APP_PORT = int(os.environ.get("APP_PORT", 8080))

PROJECT_ID = os.environ.get("PROJECT_ID")
DATASET_ID = os.environ.get("DATASET_ID")
TABLE_NAME = os.environ.get("TABLE_NAME")
TABLE_ID = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_NAME}"

client = bigquery.Client(project=PROJECT_ID)


@mcp.tool()
def apply_leave(employee_id: int, start_date: str, end_date: str) -> str:
    """
    Records an employee leave request in BigQuery.

    Args:
        employee_id: Numeric employee identifier.
        start_date:  Leave start date in YYYY-MM-DD format.
        end_date:    Leave end date in YYYY-MM-DD format.

    Returns:
        Confirmation string with the inserted record details.
    """
    row = [
        {
            "employee_id": employee_id,
            "leave_start_date": start_date,
            "leave_end_date": end_date,
        }
    ]
    errors = client.insert_rows_json(TABLE_ID, row)
    if errors:
        raise RuntimeError(f"BigQuery insert failed: {errors}")
    print(f"Inserted into {TABLE_ID}: {row}")
    return f"Leave applied successfully: {json.dumps(row[0])}"


sse = SseServerTransport("/messages/")


async def handle_sse(request: Request) -> None:
    _server = mcp._mcp_server
    async with sse.connect_sse(
        request.scope,
        request.receive,
        request._send,
    ) as (reader, writer):
        await _server.run(reader, writer, _server.create_initialization_options())


app = Starlette(
    debug=True,
    routes=[
        Route("/sse", endpoint=handle_sse),
        Mount("/messages/", app=sse.handle_post_message),
    ],
)

if __name__ == "__main__":
    uvicorn.run(app, host=APP_HOST, port=APP_PORT)
